defmodule Zaq.Agent.RequestControl do
  @moduledoc """
  Shared authorized request-control boundary for explicit Agent API controls and
  execution admission while a runtime is busy. Engine owns canonical admission,
  grants and durable receipts; this module owns registry/PID targeting and Jido
  control invocation. It never creates public answers or interprets provider data.
  """

  alias Zaq.Agent.{Factory, RequestRegistry}
  alias Zaq.Event
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
      case action do
        :steer_request -> factory.steer(runtime, content, opts)
        :inject_request -> factory.inject(runtime, content, opts)
      end
    end
  end

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
