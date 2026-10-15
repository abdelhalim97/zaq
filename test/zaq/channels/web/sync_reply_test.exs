defmodule Zaq.Channels.Web.SyncReplyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Web.{Delivery, Response, SyncReply}

  setup do
    topic = "widget:#{Ecto.UUID.generate()}"
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        topic: topic,
        channel_config_id: 1,
        conversation_id: "chat",
        message_id: "assistant",
        events: %{message_complete: "complete", error: "error", status: "status"}
      })

    %{delivery: delivery}
  end

  property "a sync terminal is returned once without consumer rebroadcast", %{delivery: delivery} do
    check all(type <- member_of([:message_complete, :message_failed]), max_runs: 10) do
      result =
        SyncReply.run(
          delivery,
          "request",
          fn internal ->
            publish(internal, "request", type, %{body: "Done"})
            publish(internal, "request", :message_failed, %{body: "late"})
            :ok
          end,
          1_000
        )

      assert %Response{type: ^type, message_id: "assistant", payload: %{body: "Done"}} = result
      refute_received {:web_response, _, _}
    end
  end

  test "a no-answer submission acknowledgement returns without awaiting a terminal", %{
    delivery: delivery
  } do
    assert %Response{type: :status, message_id: nil, payload: %{accepted: true}} =
             SyncReply.run(
               delivery,
               "request",
               fn internal ->
                 publish(%{internal | message_id: nil}, "request", :status, %{accepted: true})
                 :ok
               end,
               1_000
             )

    refute_received {:web_response, _, _}
  end

  test "transport timeout reports unknown outcome and never cancels accepted work", %{
    delivery: delivery
  } do
    parent = self()

    assert %Response{type: :error, payload: %{code: :timeout, outcome: :unknown}} =
             SyncReply.run(
               delivery,
               "request",
               fn _internal ->
                 send(parent, {:worker, self()})

                 receive do
                   :continue -> send(parent, :continued)
                 end
               end,
               20
             )

    assert_received {:worker, worker}
    assert Process.alive?(worker)
    send(worker, :continue)
    assert_receive :continued
    refute_received {:web_response, _, _}
  end

  test "dispatch failure exposes only a submission error", %{delivery: delivery} do
    assert %Response{type: :error, message_id: nil, payload: %{code: :dispatch_error}} =
             SyncReply.run(
               delivery,
               "request",
               fn _ -> {:error, %{credentials: "private"}} end,
               1_000
             )
  end

  test "dispatch exceptions expose only a correlated submission error", %{delivery: delivery} do
    assert %Response{
             protocol_version: 2,
             request_id: "request",
             conversation_id: "chat",
             type: :error,
             message_id: nil,
             payload: %{code: :dispatch_error} = payload
           } =
             SyncReply.run(
               delivery,
               "request",
               fn _ -> raise "private dispatch exception" end,
               1_000
             )

    refute inspect(payload) =~ "private dispatch exception"
    refute_received {:web_response, _, _}
  end

  test "dispatch throws expose only a correlated submission error", %{delivery: delivery} do
    assert %Response{
             protocol_version: 2,
             request_id: "request",
             conversation_id: "chat",
             type: :error,
             message_id: nil,
             payload: %{code: :dispatch_error} = payload
           } =
             SyncReply.run(
               delivery,
               "request",
               fn _ -> throw({:private_failure, "secret"}) end,
               1_000
             )

    refute inspect(payload) =~ "secret"
    refute_received {:web_response, _, _}
  end

  test "a killed dispatch worker reports a correlated submission error", %{delivery: delivery} do
    parent = self()

    task =
      Task.async(fn ->
        SyncReply.run(
          delivery,
          "request",
          fn _ ->
            send(parent, {:dispatch_worker, self()})

            receive do
              :continue -> :ok
            end
          end,
          2_000
        )
      end)

    assert_receive {:dispatch_worker, worker}
    Process.exit(worker, :kill)

    assert %Response{
             protocol_version: 2,
             request_id: "request",
             conversation_id: "chat",
             type: :error,
             message_id: nil,
             payload: %{code: :dispatch_error}
           } = Task.await(task, 1_000)

    refute_received {:web_response, _, _}
  end

  defp publish(delivery, request_id, type, payload) do
    {:ok, response} =
      Response.new(%{
        protocol_version: 2,
        request_id: request_id,
        conversation_id: delivery.conversation_id,
        message_id: delivery.message_id,
        type: type,
        payload: payload
      })

    Phoenix.PubSub.broadcast(Zaq.PubSub, delivery.topic, {:web_response, type, response})
  end
end
