defmodule Zaq.Agent.RequestControl do
  @moduledoc """
  Shared authorized request-control boundary for explicit Agent API controls and
  execution admission while a runtime is busy. Engine owns canonical admission,
  grants and durable receipts; this module owns registry/PID targeting and Jido
  control invocation. It never creates public answers or interprets provider data.
  """

  alias Zaq.Agent.{Answering, Factory, RequestRegistry}
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Identity.ExecutionActor

  @doc "Returns private request state only to the same currently authorized principal."
  def authorize(event, request_id) do
    with {:ok, state} when is_map(state) <- RequestRegistry.get(request_id),
         {:ok, identity} <- ExecutionActor.identity(event.actor),
         {:ok, ^identity} <- ExecutionActor.identity(state[:actor]),
         :ok <- matching_scope(event.request, state),
         :ok <- authorize_person(event, state, identity) do
      {:ok, state}
    else
      {:error, reason} when reason in [:not_found, :scope_conflict] -> {:error, reason}
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Queues authorized canonical input before controlling the exact Jido incarnation."
  def control(event, request_id, content, action, binding)
      when action in [:steer_request, :inject_request] do
    factory = Keyword.get(event.opts, :factory_module, Factory)

    with {:ok, state} <- authorize(event, request_id),
         {:ok, runtime} <- runtime(state),
         {:ok, opts} <- input_opts(event, state, content, request_id, binding) do
      invoke_control(factory, runtime, content, action, opts)
      |> retain_rejection(event, state, opts)
    end
  end

  defp invoke_control(factory, runtime, content, :steer_request, opts) do
    factory.steer(runtime, content, opts)
  catch
    :exit, _ -> {:error, :stale_runtime}
  end

  defp invoke_control(factory, runtime, content, :inject_request, opts) do
    factory.inject(runtime, content, opts)
  catch
    :exit, _ -> {:error, :stale_runtime}
  end

  defp retain_rejection({:error, reason} = result, event, state, opts) do
    case Keyword.get(opts, :extra_refs) do
      %{message_id: id} -> persist_rejection(event, state, id, reason, result)
      _ -> result
    end
  end

  defp retain_rejection(result, _event, _state, _opts), do: result

  defp persist_rejection(event, state, input_id, reason, result) do
    router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

    request =
      Event.new(
        %{
          root_user_message_id: state.execution_user_message_id,
          user_message_id: input_id,
          reason: reason
        },
        :engine,
        actor: event.actor,
        opts: [action: :reject_execution_input, confidential: true]
      )

    case router.dispatch(request) do
      %{response: :ok} -> result
      %{response: {:error, :input_consumed}} -> {:error, :input_consumed}
      %{response: {:error, failure}} -> {:error, {:input_receipt_failed, failure}}
      _ -> {:error, {:input_receipt_failed, :unavailable}}
    end
  end

  @doc "Routes a verified same-Person explicit incoming input before request status side effects."
  def queue_incoming(
        event,
        incoming,
        %{kind: :canonical, transcript_id: transcript_id},
        binding,
        agent_id
      ) do
    scope = "history:#{transcript_id}:person:#{ActorNormalizer.person_id(event.actor)}"
    agent_id = agent_id || Answering.answering_configured_agent().id

    case RequestRegistry.find_active(scope, event.actor, %{agent_id: agent_id}) do
      {:ok, {request_id, _state}} ->
        case control(event, request_id, incoming.content, :steer_request, binding) do
          {:ok, _} ->
            {:queued,
             Outgoing.from_pipeline_result(incoming, %{
               answer: "",
               error: false,
               execution_disposition: "queued",
               root_request_id: request_id
             })}

          {:error, _} = error ->
            error
        end

      {:error, :not_found} ->
        :not_active

      {:error, _} = error ->
        error
    end
  end

  def queue_incoming(_event, _incoming, _projection, _binding, _agent_id), do: :not_active

  defp runtime(%{status: status}) when status in [:completed, :failed, :cancelled],
    do: {:error, :terminal_request}

  defp runtime(%{runtime_pid: pid}) when is_pid(pid),
    do: if(Process.alive?(pid), do: {:ok, pid}, else: {:error, :stale_runtime})

  defp runtime(%{runtime_pid: _}), do: {:error, :stale_runtime}
  defp runtime(%{server_id: id}) when not is_nil(id), do: {:ok, id}
  defp runtime(_state), do: {:error, :missing_server_id}

  defp input_opts(_event, %{execution_user_message_id: id}, _content, _request_id, nil)
       when is_binary(id), do: {:error, :admission_required}

  defp input_opts(event, %{execution_user_message_id: id}, content, request_id, binding)
       when is_binary(id), do: queue_input(event, id, binding, content, request_id)

  defp input_opts(_event, _state, _content, request_id, _binding),
    do: {:ok, [expected_request_id: request_id]}

  defp queue_input(event, root_id, binding, content, request_id) do
    router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

    request =
      Event.new(%{root_user_message_id: root_id, binding: binding, content: content}, :engine,
        actor: event.actor,
        opts: [action: :queue_execution_input, confidential: true]
      )

    case router.dispatch(request) do
      %{response: {:ok, receipt}} ->
        {:ok, [expected_request_id: request_id, extra_refs: receipt.refs]}

      %{response: {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :history_unavailable}
    end
  end

  defp matching_scope(request, state) do
    expected = state[:execution_scope]

    case Map.get(request, :execution_scope, Map.get(request, "execution_scope")) do
      nil -> :ok
      ^expected -> :ok
      _ -> {:error, :scope_conflict}
    end
  end

  defp authorize_person(event, state, {:person, _id}) do
    router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

    request =
      Event.new(%{user_message_id: state[:execution_user_message_id]}, :engine,
        actor: event.actor,
        opts: [action: :authorize_execution_control, confidential: true]
      )

    case router.dispatch(request) do
      %{response: :ok} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp authorize_person(_event, _state, _identity), do: :ok
end
