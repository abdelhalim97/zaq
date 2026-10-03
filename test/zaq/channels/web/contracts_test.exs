defmodule Zaq.Channels.Web.ContractsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}

  describe "Message.new/1" do
    test "normalizes a BO message without accepting trusted context fields" do
      timestamp = DateTime.utc_now()

      assert {:ok, message} =
               Message.new(%{
                 "request_id" => " request-1 ",
                 "message_id" => " message-1 ",
                 "content" => " hello ",
                 "timestamp" => timestamp,
                 "channel" => " bo ",
                 "mode" => "async",
                 "conversation_id" => " conversation-1 ",
                 "author_id" => " 42 ",
                 "author_name" => " Ada "
               })

      assert message.request_id == "request-1"
      assert message.message_id == "message-1"
      assert message.content == "hello"
      assert message.timestamp == timestamp
      assert message.channel == "bo"
      assert message.mode == :async
      assert message.conversation_id == "conversation-1"
      assert message.author_id == "42"
      assert message.author_name == "Ada"

      assert {:error, {:unknown_fields, ["actor"]}} =
               Message.new(%{
                 request_id: "request-1",
                 message_id: "message-1",
                 content: "hello",
                 timestamp: timestamp,
                 channel: "bo",
                 mode: :async,
                 actor: %{user_id: 42}
               })
    end

    test "rejects blank content, malformed timestamps and unsupported modes" do
      valid = %{
        request_id: "request-1",
        message_id: "message-1",
        content: "hello",
        timestamp: DateTime.utc_now(),
        channel: "bo",
        mode: :async
      }

      assert {:error, {:invalid_field, :content}} = Message.new(%{valid | content: "  "})
      assert {:error, {:invalid_field, :timestamp}} = Message.new(%{valid | timestamp: "today"})
      assert {:error, {:invalid_field, :mode}} = Message.new(%{valid | mode: "later"})
    end

    property "arbitrary modes never create atoms" do
      check all(
              mode <- string(:alphanumeric, min_length: 1, max_length: 32),
              mode not in ["async", "sync"]
            ) do
        before = :erlang.system_info(:atom_count)

        assert {:error, {:invalid_field, :mode}} =
                 Message.new(%{
                   request_id: "request-1",
                   message_id: "message-1",
                   content: "hello",
                   timestamp: DateTime.utc_now(),
                   channel: "bo",
                   mode: mode
                 })

        assert :erlang.system_info(:atom_count) == before
      end
    end
  end

  describe "Command.new/1" do
    test "accepts only initialization and history commands" do
      assert {:ok, init} = Command.new(%{request_id: "r1", type: "conversation.init"})
      assert init.type == :conversation_init
      assert init.conversation_id == nil
      assert init.params == %{}

      assert {:ok, history} =
               Command.new(%{
                 request_id: "r2",
                 type: :conversation_history,
                 conversation_id: "conversation-1",
                 params: %{limit: 50}
               })

      assert history.type == :conversation_history
      assert history.conversation_id == "conversation-1"

      assert {:error, {:invalid_field, :type}} =
               Command.new(%{request_id: "r3", type: "message.edit"})
    end

    test "rejects trusted or executable fields in command params" do
      assert {:error, {:unknown_fields, ["actor", "delivery"]}} =
               Command.new(%{
                 request_id: "r1",
                 type: :conversation_init,
                 actor: %{user_id: 1},
                 delivery: %{topic: "chosen-by-browser"}
               })

      assert {:error, {:forbidden_params, ["mfa"]}} =
               Command.new(%{
                 request_id: "r1",
                 type: :conversation_init,
                 params: %{"mfa" => {Kernel, :apply, []}}
               })
    end
  end

  describe "Context.new/2" do
    test "requires trusted actor context for BO permission capabilities" do
      delivery = Delivery.bo("chat:session-1")

      assert {:ok, context} =
               Context.new(
                 %{user_id: 42, person: %{id: 7}},
                 consumer: :bo,
                 capabilities: [:skip_permissions],
                 delivery: delivery,
                 selected_agent_id: "agent-1",
                 content_filter: ["docs/"]
               )

      assert context.actor.user_id == 42
      assert context.capabilities == MapSet.new([:skip_permissions])

      assert {:error, :unauthorized} =
               Context.new(nil,
                 consumer: :bo,
                 capabilities: [:skip_permissions],
                 delivery: delivery
               )
    end

    test "nil identity cannot acquire implicit capabilities" do
      assert {:ok, context} = Context.new(nil, consumer: :widget, capabilities: [])
      assert context.actor == nil
      assert context.capabilities == MapSet.new()

      assert {:error, {:invalid_capability, :admin}} =
               Context.new(%{user_id: 1}, consumer: :bo, capabilities: [:admin])
    end
  end

  describe "Delivery.new/1" do
    test "normalizes a trusted BO delivery descriptor" do
      assert {:ok, delivery} =
               Delivery.new(%{
                 consumer: :bo,
                 topic: "chat:session-1",
                 protocol_version: 1,
                 events: %{
                   status: :status_update,
                   message_complete: :pipeline_result,
                   error: :pipeline_result
                 }
               })

      assert delivery.topic == "chat:session-1"
      assert delivery.events.status == :status_update
    end

    test "rejects unknown semantic events and malformed topics" do
      assert {:error, {:invalid_event, :execute_mfa}} =
               Delivery.new(%{
                 consumer: :bo,
                 topic: "chat:session-1",
                 events: %{execute_mfa: :run}
               })

      assert {:error, {:invalid_field, :topic}} =
               Delivery.new(%{consumer: :bo, topic: "  ", events: %{}})
    end
  end

  describe "Response.new/1" do
    test "builds a versioned semantic response with correlation" do
      assert {:ok, response} =
               Response.new(%{
                 request_id: "request-1",
                 type: :message_complete,
                 conversation_id: "conversation-1",
                 message_id: "message-1",
                 payload: %{body: "answer"}
               })

      assert response.protocol_version == 1
      assert response.type == :message_complete
      assert response.payload == %{body: "answer"}
    end

    test "rejects private execution fields in public payloads" do
      assert {:error, {:forbidden_payload, ["finalization_token"]}} =
               Response.new(%{
                 request_id: "request-1",
                 type: :message_failed,
                 payload: %{finalization_token: "private"}
               })
    end
  end
end
