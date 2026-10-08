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

  @doc "Runs an internal completion session and disposes any unconfirmed runtime on exit."
  def with_session(fun) do
    session = make_ref()

    try do
      fun.(session)
    after
      Enum.each(ServerManager.history_requests(session), fn request ->
        ServerManager.abort_history_request(request.server_id, request.lease.token)
      end)
    end
  end

  @doc "Acquires canonical admission and uses the incorporated cursor as the fixed turn cursor."
  def admit(opts, server_id, pid, actor) do
    case Keyword.get(opts, :execution_history) do
      nil ->
        {:ok, opts}

      history ->
        with {:ok, lease} <- ServerManager.begin_history_request(server_id, pid, actor),
             :ok <-
               ServerManager.bind_history_request(server_id, lease.token, %{
                 session: Keyword.fetch!(opts, :history_session),
                 history: history,
                 actor: actor,
                 router: Keyword.get(opts, :node_router, Zaq.NodeRouter)
               }) do
          {:ok, Keyword.put(opts, :execution_history, %{history | cursors: lease.cursors})}
        end
    end
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
        opts: [action: :execution_history, confidential: true]
      )

    case details.router.dispatch(event) do
      %{response: {:ok, %{kind: :canonical} = projection}} ->
        context =
          context
          |> HistoryLoader.bind_completed_answer(persisted[:assistant_message_id], answer)
          |> HistoryLoader.complete_projection(projection.messages,
            opaque_alias_scope: details.history.scope
          )

        # A capped page publishes only its read cursors. Remaining associations
        # are reread before the next model call from these incorporated cursors.
        {:ok, context, projection.cursors}

      %{response: {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :history_unavailable}
    end
  end
end
