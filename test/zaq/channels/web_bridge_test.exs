defmodule Zaq.Channels.WebBridgeTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.{Context, Delivery, Message, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Messages.Incoming.RoutingContext

  setup do
    topic = "chat:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)
    delivery = Delivery.bo(topic)

    routing_context = %RoutingContext{
      attributes: %{"web_delivery" => Delivery.reference(delivery)}
    }

    %{delivery: delivery, routing_context: routing_context}
  end

  test "translates normalized message correlation and original content", %{delivery: delivery} do
    {:ok, message} =
      Message.new(%{
        content: "hello",
        channel: "bo",
        mode: :sync,
        timestamp: DateTime.utc_now(),
        request_id: "r1",
        message_id: "m1"
      })

    {:ok, context} = Context.new(%{user_id: 1}, consumer: :bo, delivery: delivery)
    assert %Incoming{} = incoming = WebBridge.to_internal(message, context)
    assert incoming.provider == :web
    assert incoming.channel_id == "bo"
    assert incoming.message_id == "m1"
    assert incoming.metadata.request_id == "r1"
    assert incoming.metadata.user_content == "hello"
  end

  test "publishes normalized final response", %{routing_context: routing_context} do
    outgoing = %Outgoing{
      body: "answer",
      provider: :web,
      channel_id: "bo",
      routing_context: routing_context,
      metadata: %{request_id: "r1", user_content: "question"}
    }

    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing, %{})

    assert_receive {:web_response, :pipeline_result,
                    %Response{
                      request_id: "r1",
                      type: :message_complete,
                      payload: %{body: "answer", user_content: "question"}
                    }}
  end

  test "streaming upsert preserves atom stage and replacement intent", %{routing_context: context} do
    request = %{
      request_id: "r1",
      body: "Full response",
      intent_meta: %{stage: :retrieving},
      update_intent: :stream_delta,
      routing_context: context
    }

    assert {:ok, %{action: :created, message_id: "r1", update_intent: :stream_delta}} =
             WebBridge.upsert_message(%{}, request, %{})

    assert_receive {:web_response, :status_update,
                    %Response{
                      type: :message_edit,
                      payload: %{
                        stage: :retrieving,
                        body: "Full response",
                        update_intent: :stream_delta
                      }
                    }}
  end

  test "upsert retains existing message correlation", %{routing_context: context} do
    request = %{
      request_id: "r1",
      message_id: "assistant-1",
      body: "Revised",
      routing_context: context
    }

    assert {:ok, %{action: :updated, message_id: "assistant-1"}} =
             WebBridge.upsert_message(%{}, request, %{})

    assert_receive {:web_response, :status_update, %Response{message_id: "assistant-1"}}
  end

  test "missing correlation or content is a no-op", %{routing_context: context} do
    for fields <- [
          %{request_id: nil, body: "answer"},
          %{request_id: "r1", body: nil},
          %{request_id: "r1", body: ""}
        ] do
      request = Map.merge(fields, %{update_intent: :stream_delta, routing_context: context})

      assert {:ok, %{action: :noop, message_id: nil}} =
               WebBridge.upsert_message(%{}, request, %{})

      refute_receive {:web_response, _, _}
    end
  end

  test "string and absent stages default to answering", %{routing_context: context} do
    for intent_meta <- [%{stage: "retrieving"}, nil] do
      request = %{
        request_id: "r1",
        body: "Status",
        intent_meta: intent_meta,
        routing_context: context
      }

      assert {:ok, %{action: :created}} = WebBridge.upsert_message(%{}, request, %{})
      assert_receive {:web_response, :status_update, %Response{payload: %{stage: :answering}}}
    end
  end

  test "rejects final and status delivery without a trusted descriptor" do
    outgoing = %Outgoing{body: "answer", provider: :web, channel_id: "bo"}
    assert {:error, :missing_delivery_descriptor} = WebBridge.send_reply(outgoing, %{})

    assert {:error, :missing_delivery_descriptor} =
             WebBridge.upsert_message(%{}, %{body: "answer"}, %{})

    refute_receive {:web_response, _, _}
  end
end
