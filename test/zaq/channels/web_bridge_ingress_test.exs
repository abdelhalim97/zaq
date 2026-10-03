defmodule Zaq.Channels.WebBridgeIngressTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures

  alias Zaq.Channels.Api
  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias ZaqWeb.Chat.BridgeClient

  defmodule LocalNodeRouter do
    alias Zaq.Engine.Api, as: EngineApi
    alias Zaq.Engine.Messages.Outgoing
    alias Zaq.Event

    def dispatch(%Event{opts: opts} = event) do
      case Keyword.fetch!(opts, :action) do
        :web_ingress ->
          Zaq.Channels.Api.handle_event(event, :web_ingress, nil)

        :route_incoming_message ->
          send(self(), {:engine_routing_event, event})

          %{
            event
            | response: %Outgoing{
                body: "answer",
                channel_id: event.request.channel_id,
                provider: :web,
                routing_context: event.request.routing_context,
                metadata: event.request.metadata
              }
          }

        :conversation ->
          send(self(), {:engine_conversation_event, event})

          if Process.get(:engine_unavailable) do
            %{event | response: {:error, :engine_unavailable}}
          else
            EngineApi.handle_event(event, :conversation, nil)
          end
      end
    end
  end

  describe ":web_ingress" do
    test "BO client dispatches through the Channels role instead of invoking WebBridge" do
      actor = %{user_id: 42, person: %{id: 7, full_name: "Ada", team_ids: []}}

      assert %Outgoing{} =
               BridgeClient.dispatch_message(
                 %{
                   request_id: "request-client",
                   message_id: "message-client",
                   content: "question",
                   timestamp: DateTime.utc_now(),
                   channel: "bo",
                   mode: :sync,
                   author_id: "42"
                 },
                 actor,
                 consumer: :bo,
                 capabilities: [:skip_permissions],
                 delivery: Delivery.bo("chat:session-client"),
                 node_router: LocalNodeRouter
               )

      assert_received {:engine_routing_event, %Event{request: %Incoming{}}}

      assert {:error, {:invalid_field, :type}} =
               BridgeClient.dispatch_command(
                 %{request_id: "invalid", type: "message.edit"},
                 actor,
                 consumer: :bo,
                 node_router: LocalNodeRouter
               )
    end

    test "routes a normalized BO message as canonical Incoming with trusted options", %{test: _} do
      actor = %{user_id: 42, person: %{id: 7, full_name: "Ada", team_ids: [3]}}
      delivery = Delivery.bo("chat:session-1")

      assert {:ok, context} =
               Context.new(actor,
                 consumer: :bo,
                 capabilities: [:skip_permissions],
                 delivery: delivery,
                 selected_agent_id: "agent-1",
                 content_filter: ["docs/legal"],
                 history: %{question: "previous answer"}
               )

      assert {:ok, message} =
               Message.new(%{
                 request_id: "request-1",
                 message_id: "message-1",
                 content: "question",
                 timestamp: DateTime.utc_now(),
                 channel: "bo",
                 mode: :sync,
                 conversation_id: Ecto.UUID.generate(),
                 author_id: "42",
                 author_name: "Ada"
               })

      event =
        Event.new(%{payload: message, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Outgoing{} = Api.handle_event(event, :web_ingress, nil).response

      assert_received {:engine_routing_event,
                       %Event{
                         request: %Incoming{} = incoming,
                         actor: ^actor,
                         opts: engine_opts
                       }}

      assert incoming.content == "question"
      assert incoming.provider == :web
      assert incoming.message_id == "message-1"
      assert incoming.content_filter == ["docs/legal"]
      assert incoming.routing_context.conversation_id == message.conversation_id

      assert incoming.routing_context.attributes == %{
               "configured_agent_id" => "agent-1",
               "routing_source" => "bo_explicit"
             }

      assert incoming.metadata[:request_id] == "request-1"
      assert incoming.metadata[:session_id] == "session-1"
      assert engine_opts[:pipeline_opts][:history] == %{question: "previous answer"}
      assert engine_opts[:pipeline_opts][:skip_permissions] == true
      assert engine_opts[:pipeline_opts][:node_router] == LocalNodeRouter
    end

    test "rejects a context whose actor does not match the event actor" do
      assert {:ok, context} = Context.new(%{user_id: 1}, consumer: :bo)

      assert {:ok, command} =
               Command.new(%{request_id: "request-1", type: :conversation_init})

      event =
        Event.new(%{payload: command, context: context}, :channels,
          actor: %{user_id: 2},
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert Api.handle_event(event, :web_ingress, nil).response == {:error, :unauthorized}
      refute_received {:engine_conversation_event, _}
    end

    test "initializes and restores a BO conversation without entering message routing" do
      user = user_fixture()
      actor = %{user_id: user.id}
      assert {:ok, context} = Context.new(actor, consumer: :bo)

      assert {:ok, init} = Command.new(%{request_id: "init-1", type: :conversation_init})

      init_event =
        Event.new(%{payload: init, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Response{
               type: :conversation_initialized,
               conversation_id: conversation_id,
               payload: %{created: true}
             } = Api.handle_event(init_event, :web_ingress, nil).response

      conversation = Conversations.get_conversation!(conversation_id)
      assert conversation.user_id == user.id
      assert conversation.channel_user_id == "bo_user_#{user.id}"

      {:ok, persisted} =
        Conversations.add_message(conversation, %{role: "user", content: "Persisted question"})

      assert {:ok, history} =
               Command.new(%{
                 request_id: "history-1",
                 type: :conversation_history,
                 conversation_id: conversation_id
               })

      history_event =
        Event.new(%{payload: history, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Response{
               type: :conversation_history,
               conversation_id: ^conversation_id,
               payload: %{messages: [%{id: message_id, content: "Persisted question"}]}
             } = Api.handle_event(history_event, :web_ingress, nil).response

      assert message_id == persisted.id
      refute_received {:engine_routing_event, _}
    end

    test "BO initialization falls back to a fresh conversation for a missing id" do
      user = user_fixture()
      actor = %{user_id: user.id}
      assert {:ok, context} = Context.new(actor, consumer: :bo)
      missing_id = Ecto.UUID.generate()

      assert {:ok, init} =
               Command.new(%{
                 request_id: "init-missing",
                 type: :conversation_init,
                 conversation_id: missing_id
               })

      event =
        Event.new(%{payload: init, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Response{
               conversation_id: created_id,
               payload: %{created: true, replaced_missing_id: ^missing_id}
             } = Api.handle_event(event, :web_ingress, nil).response

      refute created_id == missing_id
    end

    test "returns a structured response when Engine conversation dispatch fails" do
      user = user_fixture()
      actor = %{user_id: user.id}
      assert {:ok, context} = Context.new(actor, consumer: :bo)
      assert {:ok, command} = Command.new(%{request_id: "init-failed", type: :conversation_init})
      Process.put(:engine_unavailable, true)

      event =
        Event.new(%{payload: command, context: context}, :channels,
          actor: actor,
          opts: [action: :web_ingress, node_router: LocalNodeRouter]
        )

      assert %Response{
               type: :error,
               request_id: "init-failed",
               payload: %{code: :engine_unavailable}
             } = Api.handle_event(event, :web_ingress, nil).response
    end
  end
end
