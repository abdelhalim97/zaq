defmodule Zaq.Agent.HistorySync do
  @moduledoc """
  Internal coordinator for authorized history at handled request boundaries.

  API owns outcome persistence; ServerManager owns exclusive admission and exact
  runtime incarnations; Engine owns grants and association cursors. Completion
  sessions remain local process-owned references, never message metadata or tool
  capabilities. An unfinished session disposes its runtimes rather than retaining
  uncommitted exchanges.
  """

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.{HistoryLoader, ServerManager}
  alias Zaq.Event
  alias Zaq.Identity.ExecutionActor

  @doc "Runs an internal completion session and disposes any unconfirmed runtime on exit."
  def with_session(fun) do
    session = make_ref()
    Process.put({__MODULE__, session}, %{})

    try do
      fun.(session)
    after
      Process.delete({__MODULE__, session})

      Enum.each(ServerManager.history_requests(session), fn request ->
        ServerManager.abort_history_request(request.server_id, request.lease.token)
      end)

      ServerManager.release_history_pins(session)
    end
  end

  @doc "Carries an Engine admission only within its owning live completion session."
  def execution_admission(opts, binding, actor, content) do
    session = Keyword.get(opts, :history_session)
    key = {binding, ExecutionActor.identity(actor), content}
    admissions = Process.get({__MODULE__, session})

    case admissions && Map.fetch(admissions, key) do
      {:ok, projection} -> {:ok, projection}
      _ -> fetch_admission(opts, binding, actor, content, admissions)
    end
  end

  defp fetch_admission(opts, binding, actor, content, admissions) do
    event =
      Event.new(%{binding: binding, content: content}, :engine,
        actor: actor,
        opts: [action: :admit_execution, confidential: true]
      )

    router = Keyword.get(opts, :node_router, Zaq.NodeRouter)

    case router.dispatch(event) do
      %{response: {:ok, projection}} ->
        if is_map(admissions) do
          pin_admission(projection, actor, Keyword.fetch!(opts, :history_session))

          Process.put(
            {__MODULE__, Keyword.fetch!(opts, :history_session)},
            Map.put(admissions, {binding, ExecutionActor.identity(actor), content}, projection)
          )
        end

        {:ok, projection}

      %{response: {:error, {:history_access_denied, denial}}} ->
        :ok = ServerManager.retire_history_scope(denial)
        {:error, {:history_access_denied, denial}}

      %{response: {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :history_unavailable}
    end
  end

  defp pin_admission(%{kind: :canonical, transcript_id: transcript_id}, actor, session),
    do: ServerManager.pin_history_scope(transcript_id, actor, session)

  defp pin_admission(_projection, _actor, _session), do: :ok

  @doc "Transfers the current invocation's admission to Engine's uniquely linked recovery root."
  def inherit_admission(opts, binding, recovered, actor, content) do
    session = Keyword.fetch!(opts, :history_session)
    admissions = Process.get({__MODULE__, session})

    case admissions && Map.fetch(admissions, {binding, ExecutionActor.identity(actor), content}) do
      {:ok, projection} ->
        Process.put(
          {__MODULE__, session},
          Map.put(admissions, {recovered, ExecutionActor.identity(actor), content}, projection)
        )

        :ok

      _ ->
        {:error, :admission_required}
    end
  end

  @doc "Acquires canonical admission and uses the incorporated cursor as the fixed turn cursor."
  def admit(opts, server_id, pid, actor) do
    case Keyword.get(opts, :execution_history) do
      nil ->
        {:ok, opts}

      history ->
        with {:ok, lease} <- admit_lease(opts, server_id, pid, actor, history) do
          history =
            history
            |> Map.put(:cursors, lease.cursors)
            |> Map.put(:lease_ref, {server_id, pid, lease.token})

          {:ok, Keyword.put(opts, :execution_history, history)}
        end
    end
  end

  @doc "Reserves live followup admission inside the caller's existing completion session."
  @spec reserve_followup(reference(), map(), map(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def reserve_followup(session, disposition, actor, input_id, timeout) do
    existing =
      Enum.find(
        ServerManager.history_requests(session),
        &(&1.lease.pid == disposition.runtime_pid)
      )

    case existing do
      nil ->
        with {:ok, reservation} <-
               ServerManager.reserve_history_request(
                 disposition.runtime_pid,
                 actor,
                 input_id,
                 timeout
               ) do
          bind_reservation(reservation, %{session: session, actor: actor, input_id: input_id})
        end

      request ->
        if get_in(request, [:lease, :details, :history, :binding, :user_message_id]) == input_id,
          do:
            {:ok,
             %{
               server_id: request.server_id,
               lease: Map.take(request.lease, [:token, :op_id, :pid, :cursors])
             }},
          else: {:error, :history_binding_conflict}
    end
  end

  defp bind_reservation(reservation, details) do
    case ServerManager.bind_history_request(
           reservation.server_id,
           reservation.lease.token,
           details
         ) do
      :ok ->
        {:ok, reservation}

      error ->
        ServerManager.abort_history_request(reservation.server_id, reservation.lease.token)
        error
    end
  end

  defp admit_lease(opts, server_id, pid, actor, history) do
    details = %{
      session: Keyword.fetch!(opts, :history_session),
      history: history,
      actor: actor,
      router: Keyword.get(opts, :node_router, Zaq.NodeRouter)
    }

    case Keyword.get(opts, :history_reservation) do
      nil ->
        with {:ok, lease} <- ServerManager.begin_history_request(server_id, pid, actor),
             :ok <-
               ServerManager.bind_history_request(
                 server_id,
                 lease.token,
                 lease_details(details, lease)
               ),
             do: {:ok, lease}

      %{server_id: ^server_id, lease: %{pid: ^pid} = lease} ->
        with :ok <-
               ServerManager.adopt_history_request(
                 server_id,
                 pid,
                 lease.token,
                 lease_details(details, lease)
               ),
             do: {:ok, lease}

      _ ->
        {:error, :stale_history_lease}
    end
  end

  defp lease_details(details, lease) do
    history = %{details.history | cursors: lease.cursors}
    projection = %{history.projection | cursors: lease.cursors}
    %{details | history: %{history | projection: projection}}
  end

  @doc "Confirms successful persisted outcomes before publishing the completed idle context."
  def complete(session, persisted, outgoing) do
    Enum.each(ServerManager.history_requests(session), fn request ->
      if outgoing.metadata[:error] || outgoing.metadata[:suppressed] do
        ServerManager.abort_history_request(request.server_id, request.lease.token)
      else
        synchronize(request, persisted, outgoing.body)
      end
    end)

    :ok
  end

  defp synchronize(%{server_id: server_id, lease: lease}, persisted, answer) do
    details = lease.details

    with answer_id when is_binary(answer_id) <- persisted[:assistant_message_id],
         {:ok,
          %{
            raw_state: %{
              __strategy__: %{
                context:
                  %AIContext{
                    entries: [%AIContext.Entry{role: :assistant} | _]
                  } = context
              }
            }
          }} <-
           Jido.AgentServer.status(lease.pid),
         {:ok, context, cursors} <-
           read_additions(context, details, lease.cursors, persisted, answer),
         :ok <- ServerManager.complete_history_request(server_id, lease.token, context, cursors) do
      :ok
    else
      _ -> ServerManager.abort_history_request(server_id, lease.token)
    end
  rescue
    _ -> ServerManager.abort_history_request(server_id, lease.token)
  catch
    :exit, _ -> ServerManager.abort_history_request(server_id, lease.token)
  end

  defp read_additions(context, details, cursors, persisted, answer) do
    event =
      Event.new(Map.put(details.history.binding, :after_cursors, cursors), :engine,
        actor: details.actor,
        opts: [action: :execution_history, confidential: true, trusted_access_denial: true]
      )

    case details.router.dispatch(event) do
      %{response: {:ok, %{kind: :canonical} = projection}} ->
        completed_projection(context, details, projection, persisted, answer)

      %{response: {:error, {:history_access_denied, denial}}} ->
        :ok = ServerManager.retire_history_scope(denial)
        completed_projection(context, details, details.history.projection, persisted, answer)

      %{response: {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :history_unavailable}
    end
  end

  defp completed_projection(context, details, projection, persisted, answer) do
    context =
      context
      |> HistoryLoader.bind_completed_answer(persisted[:assistant_message_id], answer)
      |> HistoryLoader.complete_projection(projection.messages,
        opaque_alias_scope: details.history.scope
      )

    # Only actually authorized/read associations are published, never captured
    # upper bounds or additions excluded by a later access denial.
    {:ok, context, projection.cursors}
  end
end
