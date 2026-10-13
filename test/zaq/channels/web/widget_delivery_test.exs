defmodule Zaq.Channels.Web.WidgetDeliveryTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.{Delivery, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  setup do
    topic = "widget:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        topic: topic,
        channel_config_id: 1,
        conversation_id: "chat",
        message_id: "assistant",
        events:
          Map.new(
            [
              :typing,
              :message_create,
              :message_edit,
              :message_step,
              :message_complete,
              :message_failed,
              :error,
              :status
            ],
            &{&1, &1}
          )
      })

    incoming =
      Incoming.new(%{
        content: "Question",
        provider: :web_widget,
        channel_id: "chat",
        message_id: "user",
        metadata: %{request_id: "request"},
        routing_context: %{attributes: %{"web_delivery" => Delivery.reference(delivery)}}
      })

    %{delivery: delivery, incoming: incoming}
  end

  test "native start creates an independent assistant stream; prior statuses create nothing", %{
    incoming: incoming
  } do
    assert {:ok, %{message_id: nil}} = status(incoming, :answering, "Pre-admission")
    refute_received {:web_response, _, _}

    assert {:ok, %{message_id: "assistant"}} = status(incoming, :execution_started, "Preparing")
    assert_received {:web_response, "typing", %Response{payload: %{active: true}}}

    assert_received {:web_response, "message_create",
                     %Response{
                       protocol_version: 2,
                       message_id: "assistant",
                       conversation_id: "chat"
                     }}

    incoming = put_in(incoming.metadata[:status_message_id], "assistant")
    status(incoming, :answering, "Snapshot", :stream_delta)

    assert_received {:web_response, "message_edit",
                     %Response{message_id: "assistant", payload: %{body: "Snapshot"}}}
  end

  test "queued input settles submission without any assistant answer", %{incoming: incoming} do
    status(incoming, :submission_accepted, "Accepted")

    assert_received {:web_response, "status",
                     %Response{message_id: nil, payload: %{accepted: true}}}

    refute_received {:web_response, "message_create", _}

    queued =
      Outgoing.from_pipeline_result(incoming, %{
        answer: "",
        error: false,
        execution_disposition: "queued",
        root_request_id: "private"
      })

    assert {:ok, %{delivered: false}} = WebBridge.send_reply(queued, %{})
    refute_received {:web_response, "message_complete", _}
  end

  test "activity projection never exposes reasoning or internal submission disposition", %{
    incoming: incoming
  } do
    incoming = put_in(incoming.metadata[:status_message_id], "assistant")
    status(incoming, :retrieving, "Private reasoning and arguments")
    assert_received {:web_response, "message_step", %Response{payload: payload}}
    assert payload.label == "Retrieving information"
    refute Map.has_key?(payload, :body)
    refute Map.has_key?(payload, :execution_disposition)
  end

  test "persistence failure ends its started stream without exposing exception details", %{
    incoming: incoming
  } do
    incoming = put_in(incoming.metadata[:status_message_id], "assistant")
    status(incoming, :failed, "Private storage exception")
    assert_received {:web_response, "typing", %Response{payload: %{active: false}}}

    assert_received {:web_response, "message_failed",
                     %Response{
                       message_id: "assistant",
                       payload: %{body: "Unable to save the response"}
                     }}

    refute_received {:web_response, "message_complete", _}
  end

  defp status(incoming, stage, body, intent \\ :status) do
    WebBridge.upsert_message(
      nil,
      %{
        routing_context: incoming.routing_context,
        request_id: "request",
        message_id: incoming.metadata[:status_message_id],
        body: body,
        update_intent: intent,
        intent_meta: %{stage: stage}
      },
      %{}
    )
  end
end
