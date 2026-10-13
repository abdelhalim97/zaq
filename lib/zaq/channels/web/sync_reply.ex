defmodule Zaq.Channels.Web.SyncReply do
  @moduledoc """
  Bounded caller-side wait for a synchronous web transport reply.

  A private subscription prevents duplicate live delivery. It neither owns nor
  cancels execution: accepted work continues after timeout or caller disconnect.
  No PID or process state crosses the routing boundary.
  """

  alias Zaq.Channels.Web.{Delivery, Response}

  @doc "Waits for a terminal response or a no-answer submission acknowledgement."
  def run(%Delivery{} = delivery, request_id, dispatch, timeout)
      when is_function(dispatch, 1) and is_integer(timeout) and timeout > 0 do
    internal = %{delivery | topic: "web-reply:#{Ecto.UUID.generate()}"}
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, internal.topic)

    try do
      {:ok, worker} =
        Task.Supervisor.start_child(Zaq.TaskSupervisor, fn ->
          dispatch_and_report(dispatch, internal, request_id)
        end)

      ref = Process.monitor(worker)

      try do
        await(internal, request_id, ref, System.monotonic_time(:millisecond) + timeout)
      after
        Process.demonitor(ref, [:flush])
      end
    after
      Phoenix.PubSub.unsubscribe(Zaq.PubSub, internal.topic)
      flush_replies(request_id, internal.conversation_id)
    end
  end

  defp dispatch_and_report(dispatch, delivery, request_id) do
    case dispatch.(delivery) do
      {:error, _} ->
        publish_error(delivery, request_id)

      {:ok, %Response{} = response} ->
        Phoenix.PubSub.broadcast(Zaq.PubSub, delivery.topic, {:web_response, :status, response})

      _ ->
        :ok
    end
  rescue
    _ -> publish_error(delivery, request_id)
  catch
    _, _ -> publish_error(delivery, request_id)
  end

  defp await(delivery, request_id, ref, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))
    conversation_id = delivery.conversation_id

    receive do
      {:web_response, _,
       %Response{request_id: ^request_id, conversation_id: ^conversation_id} = response} ->
        if settled?(response), do: response, else: await(delivery, request_id, ref, deadline)

      {:DOWN, ^ref, :process, _, :normal} ->
        await(delivery, request_id, ref, deadline)

      {:DOWN, ^ref, :process, _, _} ->
        error(delivery, request_id, %{code: :dispatch_error})
    after
      remaining -> error(delivery, request_id, %{code: :timeout, outcome: :unknown})
    end
  end

  defp settled?(%Response{type: type}) when type in [:message_complete, :message_failed, :error],
    do: true

  defp settled?(%Response{type: :status, payload: %{accepted: true}}), do: true
  defp settled?(_), do: false

  defp publish_error(delivery, request_id) do
    Phoenix.PubSub.broadcast(
      Zaq.PubSub,
      delivery.topic,
      {:web_response, :error, error(delivery, request_id, %{code: :dispatch_error})}
    )
  end

  defp error(delivery, request_id, payload) do
    {:ok, response} =
      Response.new(%{
        protocol_version: delivery.protocol_version,
        request_id: request_id,
        conversation_id: delivery.conversation_id,
        type: :error,
        payload: payload
      })

    response
  end

  defp flush_replies(request_id, conversation_id) do
    receive do
      {:web_response, _, %Response{request_id: ^request_id, conversation_id: ^conversation_id}} ->
        flush_replies(request_id, conversation_id)
    after
      0 -> :ok
    end
  end
end
