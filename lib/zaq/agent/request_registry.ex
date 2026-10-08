defmodule Zaq.Agent.RequestRegistry do
  @moduledoc """
  Lightweight registry for in-flight agent requests.

  The registry stores inspectable realtime state keyed by request id. It is used
  by the Agent API to expose request inspection and to route steer/inject signals
  to the active agent server. Updates are serialized, preserve request ownership,
  and cannot reopen a terminal request after a trailing stream event.
  """

  use GenServer

  alias Zaq.Identity.ExecutionActor

  @table :zaq_agent_request_registry
  @ownership_fields [
    :agent,
    :runtime_pid,
    :consumer_pid,
    :server_id,
    :owner_node,
    :actor,
    :execution_scope,
    :execution_user_message_id
  ]
  @terminal_statuses [:completed, :failed, :cancelled]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @spec put(String.t(), map()) :: :ok | {:error, :ownership_conflict | :terminal_request}
  def put(request_id, attrs) when is_binary(request_id) and is_map(attrs) do
    case table_ref() do
      :undefined -> :ok
      _table -> GenServer.call(__MODULE__, {:put, request_id, attrs})
    end
  end

  def put(_request_id, _attrs), do: :ok

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(request_id) when is_binary(request_id) do
    case table_ref() do
      :undefined ->
        {:error, :not_found}

      table ->
        case :ets.lookup(table, request_id) do
          [{^request_id, state}] -> {:ok, state}
          [] -> {:error, :not_found}
        end
    end
  end

  def get(_request_id), do: {:error, :not_found}

  @doc "Fences all request records bound to one removed Person/runtime incarnation."
  def remove_history_runtime(pid, person_id, input_id \\ nil)
      when is_pid(pid) and is_integer(person_id),
      do: GenServer.call(__MODULE__, {:remove_history_runtime, pid, person_id, input_id})

  @doc "Checks removal of an immutable admitted input without granting access to its private state."
  def history_removed?(input_id, actor) when is_binary(input_id) do
    with table when table != :undefined <- table_ref(),
         {:ok, identity} <- ExecutionActor.identity(actor) do
      :ets.foldl(
        fn {_id, state}, removed ->
          removed or
            (state[:execution_user_message_id] == input_id and state[:history_removed] == true and
               ExecutionActor.identity(state[:actor]) == {:ok, identity})
        end,
        false,
        table
      )
    else
      _ -> false
    end
  end

  def history_removed?(_, _), do: false

  @doc "Checks an exact removed incarnation even before its stream consumer registers a request."
  def history_runtime_removed?(pid, actor) do
    with table when table != :undefined <- table_ref(),
         {:ok, {:person, id}} <- ExecutionActor.identity(actor) do
      :ets.member(table, {:removed_runtime, pid, id})
    else
      _ -> false
    end
  end

  @doc "Finds one active local request by exact scope/principal; callers must authorize controls."
  def find_active(scope, actor, runtime \\ nil)

  def find_active(scope, actor, runtime) when is_binary(scope) do
    with table when table != :undefined <- table_ref(),
         {:ok, identity} <- ExecutionActor.identity(actor) do
      matches = scoped_requests(table, scope, identity, runtime)

      case matches do
        [match] -> {:ok, match}
        [] -> {:error, :not_found}
        _ -> {:error, :ambiguous_request}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def find_active(_scope, _actor, _runtime), do: {:error, :not_found}

  defp scoped_requests(table, scope, identity, runtime) do
    :ets.foldl(
      fn {id, state}, acc ->
        if active_owner?(state, scope, identity, runtime), do: [{id, state} | acc], else: acc
      end,
      [],
      table
    )
  end

  defp active_owner?(state, scope, identity, runtime) when is_map(state) do
    state[:execution_scope] == scope and state[:status] in [:running, :streaming] and
      matching_runtime?(state, runtime) and
      ExecutionActor.identity(state[:actor]) == {:ok, identity}
  end

  defp active_owner?(_state, _scope, _identity, _runtime), do: false

  defp matching_runtime?(_state, nil), do: true

  defp matching_runtime?(%{agent: %{id: id}}, %{agent_id: expected}),
    do: to_string(id) == to_string(expected)

  defp matching_runtime?(state, runtime) when is_pid(runtime), do: state[:runtime_pid] == runtime
  defp matching_runtime?(_state, _runtime), do: false

  @spec delete(String.t()) :: :ok
  def delete(request_id) when is_binary(request_id) do
    case table_ref() do
      :undefined -> :ok
      _table -> GenServer.call(__MODULE__, {:delete, request_id})
    end
  end

  def delete(_request_id), do: :ok

  @impl true
  def handle_call({:put, request_id, attrs}, _from, state) do
    current =
      case :ets.lookup(state.table, request_id) do
        [{^request_id, current}] -> current
        [] -> %{}
      end

    attrs = inherit_runtime_removal(attrs, current)

    result =
      cond do
        ownership_conflict?(current, attrs) ->
          {:error, :ownership_conflict}

        terminal_update_conflict?(current, attrs) ->
          {:error, :terminal_request}

        true ->
          :ets.insert(state.table, {request_id, Map.merge(current, attrs)})
          :ok
      end

    {:reply, result, state}
  end

  def handle_call({:delete, request_id}, _from, state) do
    :ets.delete(state.table, request_id)
    {:reply, :ok, state}
  end

  def handle_call({:remove_history_runtime, pid, person_id, input_id}, _from, state) do
    :ets.insert(
      state.table,
      {{:removed_runtime, pid, person_id},
       %{
         history_removed: true,
         runtime_pid: pid,
         actor: %{person: %{id: person_id}},
         status: :cancelled
       }}
    )

    if is_binary(input_id) do
      :ets.insert(
        state.table,
        {{:removed_input, input_id, person_id},
         %{
           history_removed: true,
           execution_user_message_id: input_id,
           runtime_pid: pid,
           actor: %{person: %{id: person_id}},
           status: :cancelled
         }}
      )
    end

    sinks =
      :ets.foldl(
        fn
          {id, %{runtime_pid: ^pid, actor: actor} = request}, sinks ->
            mark_history_removed(state.table, id, request, actor, person_id)
            removed_stream_sink(id, request, actor, person_id, sinks)

          _, sinks ->
            sinks
        end,
        [],
        state.table
      )

    {:reply, {:ok, sinks}, state}
  end

  defp removed_stream_sink(id, %{consumer_pid: consumer}, actor, person_id, sinks)
       when is_binary(id) and is_pid(consumer) do
    if ExecutionActor.identity(actor) == {:ok, {:person, person_id}},
      do: [{id, consumer} | sinks],
      else: sinks
  end

  defp removed_stream_sink(_id, _request, _actor, _person_id, sinks), do: sinks

  defp inherit_runtime_removal(attrs, current) do
    if map_size(current) == 0 and history_runtime_removed?(attrs[:runtime_pid], attrs[:actor]),
      do: Map.merge(attrs, %{history_removed: true, status: :cancelled}),
      else: attrs
  end

  defp terminal_update_conflict?(current, attrs) do
    (current[:history_removed] == true and attrs[:history_removed] == false) or
      (current[:status] in @terminal_statuses and
         Map.get(attrs, :status, current[:status]) != current[:status])
  end

  defp mark_history_removed(table, id, request, actor, person_id) do
    if ExecutionActor.identity(actor) == {:ok, {:person, person_id}} do
      status = if request[:status] in @terminal_statuses, do: request[:status], else: :cancelled
      :ets.insert(table, {id, Map.merge(request, %{status: status, history_removed: true})})
    end
  end

  defp ownership_conflict?(current, attrs) do
    Enum.any?(@ownership_fields, fn key ->
      not is_nil(current[key]) and Map.has_key?(attrs, key) and attrs[key] != current[key]
    end)
  end

  defp table_ref, do: :ets.whereis(@table)
end
