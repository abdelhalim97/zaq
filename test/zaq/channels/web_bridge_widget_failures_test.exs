defmodule Zaq.Channels.WebBridgeWidgetFailuresTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Event

  defmodule Router do
    def dispatch(%Event{opts: opts} = event) do
      dispatch_action(Keyword.fetch!(opts, :action), event)
    end

    defp dispatch_action(:channel_conversations, event),
      do: handle_conversation(event.request.operation, event)

    defp dispatch_action(:route_incoming_message, event),
      do: route_reply(event.request.content, event)

    defp dispatch_action(_action, event), do: %{event | response: {:error, :rejected}}

    defp handle_conversation(:prepare, event),
      do: prepare_reply(event.request.incoming.content, event)

    defp handle_conversation(_operation, event) do
      if event.request.sender_id == "raw",
        do: :raw_engine,
        else: %{event | response: :malformed}
    end

    defp prepare_reply("question", event), do: %{event | response: {:error, :forbidden}}

    defp prepare_reply("malformed prepare", event), do: %{event | response: :malformed}

    defp prepare_reply(_content, event) do
      incoming = event.request.incoming
      context = %{incoming.routing_context | conversation_id: "prepared-chat"}
      %{event | response: {:ok, %{incoming | routing_context: context}}}
    end

    defp route_reply("raise", _event), do: raise("private dispatch")
    defp route_reply("throw", _event), do: throw(:private_dispatch)
    defp route_reply(_content, event), do: %{event | response: {:error, :rejected}}
  end

  defmodule LocalConfig do
    def get(:zaq, :web_widget_sync_timeout_ms, _default), do: :invalid
    def get(_, _, default), do: default
  end

  defp widget_context(with_delivery \\ true) do
    delivery =
      if with_delivery do
        {:ok, d} =
          Delivery.new(%{
            consumer: :widget,
            topic: "widget:#{Ecto.UUID.generate()}",
            protocol_version: 2,
            channel_config_id: 123,
            conversation_id: "chat",
            message_id: "m",
            events: %{
              typing: "typing",
              message_create: "create",
              message_edit: "edit",
              message_step: "step",
              message_complete: "complete",
              message_failed: "failed",
              error: "error",
              status: "status"
            }
          })

        d
      end

    {:ok, ctx} =
      Context.new(nil,
        consumer: :widget,
        sender_id: "sender",
        channel_config_id: 123,
        delivery: delivery
      )

    ctx
  end

  defp message(mode \\ :async) do
    {:ok, msg} =
      Message.new(%{
        request_id: "request",
        message_id: "m",
        content: "question",
        channel: "widget",
        mode: mode,
        timestamp: DateTime.utc_now()
      })

    msg
  end

  test "widget scope without connector or delivery is unauthorized" do
    {:ok, ctx} = Context.new(nil, consumer: :widget, sender_id: "sender")
    assert {:error, :unauthorized} = WebBridge.handle_from_listener(%{}, message(), context: ctx)
  end

  test "widget prepare rejection remains an error" do
    assert {:error, :forbidden} =
             WebBridge.handle_from_listener(%{}, message(),
               context: widget_context(),
               node_router: Router
             )
  end

  test "widget prepare with an unexpected response is unavailable" do
    msg = %{message() | content: "malformed prepare"}

    assert {:error, :conversation_unavailable} =
             WebBridge.handle_from_listener(%{}, msg,
               context: widget_context(),
               node_router: Router
             )
  end

  test "successful prepare maps route exceptions and throws to dispatch errors" do
    for content <- ["raise", "throw"] do
      msg = %{message() | content: content}

      assert {:error, :dispatch_error} =
               WebBridge.handle_from_listener(%{}, msg,
                 context: widget_context(),
                 node_router: Router
               )
    end
  end

  test "successful async prepare returns the routing rejection, not a receipt" do
    msg = %{message() | content: "route me"}

    assert {:error, :rejected} =
             WebBridge.handle_from_listener(%{}, msg,
               context: widget_context(),
               node_router: Router
             )
  end

  test "invalid synchronous timeout uses fallback and returns correlated dispatch error" do
    msg = %{message(:sync) | content: "route me"}

    assert %Response{
             request_id: "request",
             conversation_id: "prepared-chat",
             type: :error,
             payload: %{code: :dispatch_error}
           } =
             WebBridge.handle_from_listener(%{}, msg,
               context: widget_context(),
               node_router: Router,
               config: LocalConfig
             )
  end

  test "widget command maps unexpected channel response to a v2 error" do
    assert %Response{protocol_version: 2, payload: %{code: :conversation_unavailable}} =
             WebBridge.handle_from_listener(%{}, command(),
               context: widget_context(),
               node_router: Router
             )
  end

  test "widget command maps a raw router return to engine unavailable" do
    ctx = widget_context()
    ctx = %{ctx | sender_id: "raw"}

    assert %Response{protocol_version: 2, payload: %{code: :engine_unavailable}} =
             WebBridge.handle_from_listener(%{}, command(), context: ctx, node_router: Router)
  end

  test "widget status upserts publish execution start and terminal failure events" do
    {delivery, routing} = delivery_context()

    assert {:ok, %{action: :updated}} =
             WebBridge.upsert_message(
               %{},
               %{
                 request_id: "r",
                 message_id: "m",
                 intent_meta: %{stage: :execution_started},
                 routing_context: routing
               },
               %{}
             )

    assert_receive {:web_response, "typing", %Response{request_id: "r", conversation_id: id}}
    assert id == delivery.conversation_id
    assert_receive {:web_response, "create", %Response{request_id: "r", conversation_id: id}}
    assert id == delivery.conversation_id

    assert {:ok, _} =
             WebBridge.upsert_message(
               %{},
               %{
                 request_id: "r",
                 message_id: "m",
                 intent_meta: %{stage: :failed},
                 routing_context: routing
               },
               %{}
             )

    assert_receive {:web_response, "typing", %Response{payload: %{active: false}}}

    assert_receive {:web_response, "failed",
                    %Response{payload: %{body: "Unable to save the response"}}}
  end

  test "widget stream deltas emit edits correlated to the conversation" do
    {delivery, routing} = delivery_context()

    assert {:ok, _} =
             WebBridge.upsert_message(
               %{},
               %{
                 request_id: "r",
                 message_id: "m",
                 body: "updated",
                 update_intent: :stream_delta,
                 routing_context: routing
               },
               %{}
             )

    assert_receive {:web_response, "edit",
                    %Response{request_id: "r", conversation_id: id, payload: %{body: "updated"}}}

    assert id == delivery.conversation_id
  end

  defp command do
    {:ok, cmd} = Command.new(%{request_id: "request", type: :conversation_init})
    cmd
  end

  defp delivery_context do
    topic = "widget:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        topic: topic,
        protocol_version: 2,
        channel_config_id: 123,
        conversation_id: "chat",
        message_id: "m",
        events: %{
          typing: "typing",
          message_create: "create",
          message_edit: "edit",
          message_step: "step",
          message_complete: "complete",
          message_failed: "failed",
          error: "error",
          status: "status"
        }
      })

    {delivery,
     %RoutingContext{
       channel_config_id: 123,
       attributes: %{"web_delivery" => Delivery.reference(delivery)}
     }}
  end
end
