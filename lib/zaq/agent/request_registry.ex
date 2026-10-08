defmodule Zaq.Agent.RequestRegistry do
  @moduledoc """
  Lightweight registry for in-flight agent requests.

  The registry stores inspectable realtime state keyed by request id. It is used
  by the Agent API to expose request inspection and to route steer/inject signals
  to the active agent server. Updates are serialized, preserve request ownership,
  and cannot reopen a terminal request after a trailing stream event.
  """

  use GenServer

  @table :zaq_agent_request_registry
  @ownership_fields [
    :runtime_pid,
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

    result =
      cond do
        ownership_conflict?(current, attrs) ->
          {:error, :ownership_conflict}

        current[:status] in @terminal_statuses and
            Map.get(attrs, :status, current[:status]) != current[:status] ->
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

  defp ownership_conflict?(current, attrs) do
    Enum.any?(@ownership_fields, fn key ->
      not is_nil(current[key]) and Map.has_key?(attrs, key) and attrs[key] != current[key]
    end)
  end

  defp table_ref, do: :ets.whereis(@table)
end
