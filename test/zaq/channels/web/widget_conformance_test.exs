defmodule Zaq.Channels.Web.WidgetConformanceTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.SystemConfigFixtures
  alias Zaq.TestSupport.ChannelConversationBoundary, as: ChannelConversations
  alias Zaq.TestSupport.OpenAIStub

  defmodule AdapterFixture do
    alias Zaq.Channels.WebBridge

    def ingress(payload, config_id, topic) do
      {:ok, delivery} =
        Delivery.new(%{
          consumer: :widget,
          channel_config_id: config_id,
          topic: topic,
          events:
            Map.new(
              [
                :typing,
                :message_create,
                :message_edit,
                :message_step,
                :message_complete,
                :message_failed,
                :error
              ],
              &{&1, "response.#{&1}"}
            )
        })

      {:ok, context} =
        Context.new(nil,
          consumer: :widget,
          sender_id: "verified-parent-user",
          channel_config_id: config_id,
          delivery: delivery
        )

      WebBridge.from_adapter(%{id: config_id}, payload, context: context)
    end
  end

  setup context do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    owner = self()
    hold_response = Map.get(context, :hold_response, false)
    request_count = :atomics.new(1, [])

    {spec, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          payload = Jason.decode!(body)

          if hold_response and :atomics.add_get(request_count, 1, 1) == 1 do
            send(owner, {:model_waiting, self()})

            receive do
              :release_response -> :ok
            end
          end

          if payload["stream"] do
            text = Jason.encode!(%{"delta" => "Widget answer"})

            completed =
              Jason.encode!(%{
                "response" => %{
                  "id" => "resp_widget",
                  "model" => "gpt-4.1-mini",
                  "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
                }
              })

            {200,
             "event: response.output_text.delta\ndata: #{text}\n\nevent: response.completed\ndata: #{completed}\n\n"}
          else
            response =
              if String.ends_with?(conn.request_path, "chat/completions"),
                do: OpenAIStub.chat_completion("Widget answer"),
                else: %{
                  "id" => "resp_widget",
                  "object" => "response",
                  "status" => "completed",
                  "model" => "gpt-4.1-mini",
                  "output" => [
                    %{
                      "type" => "message",
                      "role" => "assistant",
                      "content" => [%{"type" => "output_text", "text" => "Widget answer"}]
                    }
                  ],
                  "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
                }

            {200, response}
          end
        end,
        self()
      )

    start_supervised!(spec)
    OpenAIStub.seed_llm_config(endpoint, model: "gpt-4.1-mini")

    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Widget conformance",
        job: "Answer simply",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: true,
        advanced_options: %{"stream" => true}
      })

    {:ok, config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Conformance widget",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert()

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(
        %{channel_config_id: config.id},
        %{routing_mode: :agent, configured_agent_id: agent.id}
      )

    topic = "fixture-widget:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)
    %{config: config, topic: topic}
  end

  test "external fixture uses shared init/message/history through actual role boundaries", %{
    config: config,
    topic: topic
  } do
    {:ok, init} = Command.new(%{request_id: "init", type: :conversation_init})

    assert %Response{type: :widget_initialized, conversation_id: nil} =
             AdapterFixture.ingress(init, config.id, topic)

    {:ok, message} =
      Message.new(%{
        request_id: "first-question",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :sync,
        prompt_context: "Parent application context"
      })

    assert %Response{type: :message_complete, conversation_id: id, payload: %{created: true}} =
             AdapterFixture.ingress(message, config.id, topic)

    refute_receive {:web_response, _, _}
    scope = %{channel_config_id: config.id, sender_id: "verified-parent-user"}
    assert {:ok, history} = ChannelConversations.history(scope, id)

    assert Enum.map(history, & &1.content) == [
             "Parent application context",
             "Say hello",
             "Widget answer"
           ]

    {:ok, command} =
      Command.new(%{request_id: "history", type: :conversation_history, conversation_id: id})

    assert %Response{type: :conversation_history} =
             AdapterFixture.ingress(command, config.id, topic)
  end

  test "async fixture returns creation receipt and delivers a correlated final once", %{
    config: config,
    topic: topic
  } do
    {:ok, message} =
      Message.new(%{
        request_id: "async-question",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :async
      })

    assert {:ok,
            %Response{
              protocol_version: 2,
              type: :conversation_created,
              conversation_id: id,
              message_id: nil
            }} =
             AdapterFixture.ingress(message, config.id, topic)

    assert_receive {:web_response, "response.typing", %Response{payload: %{active: true}}}, 30_000

    assert_receive {:web_response, "response.message_create",
                    %Response{message_id: assistant_id}},
                   30_000

    assert_receive {:web_response, "response.message_complete",
                    %Response{
                      message_id: ^assistant_id,
                      conversation_id: ^id,
                      payload: %{body: "Widget answer"}
                    }},
                   30_000

    refute_receive {:web_response, "response.message_complete", _}
    refute_receive {:web_response, "response.message_failed", _}
  end

  test "workflow-only routing acknowledges a submission without creating an assistant", %{
    config: config,
    topic: topic
  } do
    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{
        routing_mode: :none,
        configured_agent_id: nil
      })

    {:ok, message} =
      Message.new(%{
        request_id: "workflow-only",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "An informational message",
        channel: "default",
        mode: :async
      })

    assert {:ok,
            %Response{type: :conversation_created, message_id: nil, payload: %{accepted: true}}} =
             AdapterFixture.ingress(message, config.id, topic)

    refute_receive {:web_response, "response.message_create", _}
    refute_receive {:web_response, "response.message_complete", _}
    assert Repo.aggregate(Zaq.Engine.Conversations.ExecutionRecord, :count) == 0

    sync_message = %{
      message
      | mode: :sync,
        request_id: "sync-workflow-only",
        message_id: Ecto.UUID.generate()
    }

    assert %Response{type: :status, message_id: nil, payload: %{accepted: true}} =
             AdapterFixture.ingress(sync_message, config.id, topic)

    refute_received {:web_response, _, _}
  end

  @tag hold_response: true
  test "a busy same-Person submission acknowledges steering without a separate answer", %{
    config: config,
    topic: topic
  } do
    {:ok, first} =
      Message.new(%{
        request_id: "root-question",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Say hello",
        channel: "default",
        mode: :async
      })

    assert {:ok, %Response{conversation_id: conversation, message_id: nil}} =
             AdapterFixture.ingress(first, config.id, topic)

    assert_receive {:web_response, "response.message_create",
                    %Response{request_id: "root-question", message_id: assistant}},
                   30_000

    assert_receive {:model_waiting, model}, 30_000

    {:ok, second} =
      Message.new(%{
        request_id: "additional-input",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "Keep it brief",
        channel: "default",
        conversation_id: conversation,
        mode: :sync
      })

    assert %Response{type: :status, message_id: nil, payload: %{accepted: true, created: false}} =
             AdapterFixture.ingress(second, config.id, topic)

    {:ok, third} =
      Message.new(%{
        request_id: "async-additional-input",
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: "No extra explanation",
        channel: "default",
        conversation_id: conversation,
        mode: :async
      })

    assert {:ok,
            %Response{type: :status, message_id: nil, payload: %{accepted: true, created: false}}} =
             AdapterFixture.ingress(third, config.id, topic)

    refute_receive {:web_response, "response.message_create",
                    %Response{request_id: "additional-input"}}

    assert_receive {:web_response, "response.status",
                    %Response{
                      request_id: "async-additional-input",
                      message_id: nil,
                      payload: %{accepted: true}
                    }},
                   30_000

    refute_receive {:web_response, "response.message_create",
                    %Response{request_id: "async-additional-input"}}

    send(model, :release_response)

    assert_receive {:web_response, "response.message_complete",
                    %Response{request_id: "root-question", message_id: ^assistant}},
                   30_000

    refute_receive {:web_response, "response.message_complete",
                    %Response{request_id: "additional-input"}}

    refute_receive {:web_response, "response.message_complete",
                    %Response{request_id: "async-additional-input"}}

    scope = %{channel_config_id: config.id, sender_id: "verified-parent-user"}
    assert {:ok, history} = ChannelConversations.history(scope, conversation)
    assert Enum.count(history, &(&1.role == "assistant")) == 1
    assert Enum.any?(history, &(&1.content == "Keep it brief"))
  end
end
