defmodule Zaq.Channels.MattermostSharedHistoryIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts.People
  alias Zaq.Agent.RequestRegistry
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.MattermostAdmin
  alias Zaq.Engine.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, Transcript, TranscriptMessage}
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Permissions.ChannelHistoryResource

  alias Zaq.TestSupport.{
    MattermostHistoryFixture,
    MultiAgentOpenAIStub,
    OpenAIStub,
    ToolCallingLLMStub
  }

  @keys [
    :channels,
    :chat_bridge_pipeline_module,
    :chat_bridge_node_router_module,
    :chat_bridge_accounts_module,
    :chat_bridge_permissions_module,
    :chat_bridge_supervisor_module,
    :chat_bridge_chat_module,
    :pipeline_hooks_module
  ]

  setup tags do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    owner = self()
    observe_history_commit(owner)
    previous = Map.new(@keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(@keys, &Application.delete_env(:zaq, &1))

    Application.put_env(:zaq, :channels, %{
      mattermost: %{
        bridge: JidoChatBridge,
        adapter: Jido.Chat.Mattermost.Adapter,
        ingress_mode: :webhook
      }
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)

    llm_handler = history_llm_handler(tags, owner)

    handler = fn conn, body ->
      if llm_handler && conn.request_path == "/v1/responses" do
        send(owner, {:history_llm, Jason.decode!(body)})

        initial_request? = not Map.has_key?(Jason.decode!(body), "previous_response_id")

        if tags[:input_consumption] and not String.contains?(body, "function_call_output") and
             (tags[:queue_overflow] != true or initial_request?) do
          barrier_timeout = if tags[:queue_overflow], do: 60_000, else: 10_000
          send(owner, {:history_llm_barrier, self()})

          receive do
            :release_history_llm -> :ok
          after
            barrier_timeout -> flunk("external LLM barrier was not released")
          end
        end

        llm_handler.(conn, body)
      else
        MattermostHistoryFixture.http(conn, body, owner)
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "History Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: if(tags[:authorized_execution], do: ["arithmetic.add"], else: []),
        conversation_enabled: true,
        active: true,
        advanced_options:
          if(tags[:queue_overflow],
            do: %{"stream" => false, "receive_timeout" => 120_000},
            else: %{"stream" => false}
          )
      })

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Shared Mattermost",
        provider: "mattermost",
        kind: "retrieval",
        url: String.trim_trailing(endpoint, "/v1"),
        token: "test-token",
        enabled: true,
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot"}}
      })
      |> Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Alice"})

    unless tags[:authorized_execution] do
      assert {:ok, _} =
               Zaq.Permissions.grant(
                 ChannelHistoryResource.for(
                   "mattermost",
                   config.id,
                   "shared-room"
                 ),
                 %{person_id: person.id, access_rights: ["read"]}
               )
    end

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "alice",
        channel_config_id: config.id
      })

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(
        %{channel_config_id: config.id},
        %{routing_mode: :agent, configured_agent_id: agent.id}
      )

    on_exit(fn ->
      ServerManager.stop_server(agent)
      Zaq.Channels.Supervisor.stop_bridge_runtime(config, "mattermost_#{config.id}")
    end)

    %{config: config, person: person, agent: agent}
  end

  for steering_mode <- [:explicit_control, :provider_mention] do
    @steering_mode steering_mode
    @tag :authorized_execution
    @tag :input_consumption
    test "authorized thread history and #{@steering_mode} reach the real tool-calling agent without private data",
         ctx do
      {:ok, bob} = People.create_person(%{full_name: "Bob"})

      {:ok, _} =
        People.add_channel(%{
          person_id: bob.id,
          platform: "mattermost",
          channel_identifier: "bob",
          channel_config_id: ctx.config.id
        })

      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, nil, false, %{
                 "id" => "root-human",
                 "user_id" => "bob",
                 "message" => "Authorized project root"
               })

      parent =
        Repo.one!(
          from t in Transcript,
            where: t.external_channel_id == "shared-room" and is_nil(t.parent_id)
        )

      assert {:ok, _} =
               Zaq.Permissions.grant(
                 {parent.permission_resource_type, parent.permission_resource_id},
                 %{person_id: ctx.person.id, access_rights: ["read"]}
               )

      root = Repo.get_by!(Message, external_message_id: "root-human")

      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: bob.id,
        user_message_id: root.id,
        finalization_token_hash: :crypto.hash(:sha256, "private-execution") |> Base.encode64(),
        trace_entries: [%{"content" => "FORBIDDEN_PRIVATE_TRACE"}],
        tool_results: [%{"content" => "FORBIDDEN_PRIVATE_TOOL"}]
      })
      |> Repo.insert!()

      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, "human", false, %{
                 "id" => "passive-thread",
                 "user_id" => "bob",
                 "message" => "Authorized thread evidence"
               })

      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(ctx.config, nil, false, %{
                 "id" => "forbidden-room",
                 "user_id" => "bob",
                 "channel_id" => "private-room",
                 "message" => "FORBIDDEN_OTHER_ROOM"
               })

      assert {{:ok, _}, post} = MattermostHistoryFixture.post(ctx.config, "human", true)
      assert_receive {:history_llm, request}, 5_000
      assert_receive {:history_llm_barrier, worker}, 5_000
      on_exit(fn -> send(worker, :release_history_llm) end)

      scope =
        "history:#{Repo.get_by!(Transcript, external_thread_id: "root-human").id}:person:#{ctx.person.id}"

      actor = %{person: %{id: ctx.person.id}}
      assert {:ok, {request_id, state}} = RequestRegistry.find_active(scope, actor)
      assert_rejected_control_receipt(ctx, state, actor)

      steering =
        Incoming.new(%{
          content: "@zaq Retain the arithmetic tool result",
          channel_id: "shared-room",
          author_id: "alice",
          author_name: "Alice",
          message_id: "steering-input",
          thread_id: "root-human",
          provider: :mattermost,
          person: ctx.person,
          routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
        })
        |> CommunicationBridge.put_conversation_identity()

      binding =
        case @steering_mode do
          :explicit_control ->
            assert {:ok, _} = HistoryIngress.capture(steering)
            assert {:ok, binding} = Conversations.admit_incoming(steering)

            control =
              Zaq.Event.new(
                %{
                  request_id: request_id,
                  content: steering.content,
                  conversation_binding: binding
                },
                :agent,
                actor: actor
              )

            assert %{response: {:ok, _}} =
                     Zaq.Agent.Api.handle_event(control, :steer_request, nil)

            binding

          :provider_mention ->
            assert {{:ok, _}, _} =
                     MattermostHistoryFixture.post(ctx.config, "human", true, %{
                       "id" => "steering-input",
                       "message" => steering.content
                     })

            assert_receive :history_input_queued, 5_000
            %{user_message_id: Repo.get_by!(Message, external_message_id: "steering-input").id}
        end

      assert Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id).status ==
               "queued"

      send(worker, :release_history_llm)
      input = Jason.encode!(request["input"])
      assert input =~ "Authorized project root"
      assert input =~ "Authorized thread evidence"
      assert input =~ "#{root.author_name} (#{root.author_id})"
      assert length(Regex.scan(~r/Authorized project root/, input)) == 1
      assert length(Regex.scan(~r/history question/, input)) == 1
      refute input =~ "FORBIDDEN_"

      assert_receive {:llm_tool_call, "add", %{"value" => 2, "amount" => 3}}, 5_000
      assert_receive {:llm_tool_result, "add", result}, 5_000
      assert result == %{"ok" => true, "result" => %{"result" => 5.0}}
      assert_receive {:history_llm, continuation}, 5_000
      refute Jason.encode!(continuation["input"]) =~ "FORBIDDEN_"
      assert Jason.encode!(continuation["input"]) =~ steering.content

      assert_receive {:history_post, %{"channel_id" => "shared-room", "root_id" => "root-human"}},
                     5_000

      child = Repo.get_by!(Transcript, external_thread_id: "root-human")
      answer = await_answer(child.id)
      outgoing = await_delivery_event()
      assert answer.content == "History answer"
      assert outgoing.metadata[:assistant_message_id] == answer.id
      assert outgoing.routing_context.channel_config_id == ctx.config.id
      assert Conversations.get_conversation!(answer.conversation_id).person_id == ctx.person.id
      input_message = Repo.get_by!(Message, external_message_id: post["id"])
      execution = Repo.get_by!(ExecutionRecord, user_message_id: input_message.id)
      assert execution.person_id == ctx.person.id
      assert execution.status == "completed"
      assert execution.public_answer_message_id == answer.id
      receipt = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
      assert receipt.status == "consumed"
      assert receipt.root_execution_id == execution.id
      assert receipt.public_answer_message_id == nil

      ids = Repo.all(from m in Message, select: m.id, order_by: m.id)
      count = Repo.aggregate(TranscriptMessage, :count)
      assert {{:ok, _}, ^post} = MattermostHistoryFixture.post(ctx.config, "human", true)
      assert Repo.all(from m in Message, select: m.id, order_by: m.id) == ids
      assert Repo.aggregate(TranscriptMessage, :count) == count
      refute_receive {:history_llm, _}, 200
      refute_received {:history_post, _}
      refute_received {:llm_stub_error, _}
      refute_received {:unexpected_history_http, _}
    end
  end

  for {name, root_author, mention?, answers?} <- MattermostHistoryFixture.scenarios() do
    @root_author root_author
    @mention mention?
    @answers answers?
    test name, ctx do
      {result, post} = MattermostHistoryFixture.post(ctx.config, @root_author, @mention)
      assert {:ok, %{auth_status: :ok}} = result

      # Listener processing is synchronous; this assertion checks real ingress,
      # including validation before canonical storage, rather than injecting Facts.
      input = Repo.get_by(Message, external_message_id: post["id"])
      assert input, "the actual adapter ingress must persist the message"
      assert input.content == post["message"]
      assert input.author_id == "alice"
      assert input.source_provider == "mattermost"
      assert input.source_account_key == Jason.encode!(["mattermost", ctx.config.id, nil])
      [placement] = Repo.all(from p in TranscriptMessage, where: p.message_id == ^input.id)
      transcript = Repo.get!(Transcript, placement.transcript_id)
      assert transcript.strategy == "shared"
      assert transcript.channel_config_id == ctx.config.id
      assert transcript.external_channel_id == "shared-room"

      assert transcript.external_thread_id ==
               if(@root_author, do: "root-#{@root_author}", else: nil)

      assert Zaq.Permissions.can?(
               ctx.person,
               "read",
               {transcript.permission_resource_type, transcript.permission_resource_id}
             )

      if @root_author do
        parent = Repo.get!(Transcript, transcript.parent_id)
        assert parent.external_thread_id == nil
        assert parent.channel_config_id == ctx.config.id
        assert parent.permission_resource_id == transcript.permission_resource_id
      else
        assert transcript.parent_id == nil
      end

      if @answers do
        assert_receive {:history_llm, _request}, 5_000
        assert_receive {:history_post, sent}, 5_000
        assert sent["channel_id"] == "shared-room"
        assert sent["root_id"] == if(@root_author, do: "root-#{@root_author}", else: nil)
        assert_receive {:history_update, %{"message" => "History answer"}}, 5_000
        answer = await_answer(transcript.id)
        assert answer.content == "History answer"
        outgoing = await_delivery_event()
        assert outgoing.metadata[:assistant_message_id] == answer.id
        assert outgoing.metadata[:conversation_id] == answer.conversation_id
        conversation = Conversations.get_conversation!(answer.conversation_id)
        assert conversation.person_id == ctx.person.id
        assert Repo.aggregate(Message, :count) == 2
        assert Repo.aggregate(TranscriptMessage, :count) == 2
        refute_received {:history_llm, _}
        refute_received {:history_post, _}
      else
        refute_received {:history_llm, _}
        refute_received {:history_post, _}
        assert Repo.aggregate(Message, :count) == 1
      end

      # The same transport event may be redelivered after successful processing.
      # It must retain both canonical UUIDs and must not activate a second answer.
      ids = Repo.all(from m in Message, select: m.id, order_by: m.id)
      placement_count = Repo.aggregate(TranscriptMessage, :count)
      assert {{:ok, _}, ^post} = MattermostHistoryFixture.post(ctx.config, @root_author, @mention)
      assert Repo.all(from m in Message, select: m.id, order_by: m.id) == ids
      assert Repo.aggregate(TranscriptMessage, :count) == placement_count
      refute_receive {:history_llm, _}, 200
      refute_received {:history_post, _}
      refute_received {:unexpected_history_http, _}

      if @root_author do
        admin = super_admin_fixture()

        event =
          Zaq.Event.new(%{op: :detail, id: transcript.id}, :engine,
            actor: %{user_id: admin.id},
            opts: [action: :channel_history_admin, confidential: true]
          )

        assert %{response: {:ok, %{root_message: root}}} =
                 Api.handle_event(event, :channel_history_admin, %{})

        assert root.content == "Root message"
        assert root.author_id == @root_author
        assert Repo.all(from m in Message, select: m.id, order_by: m.id) == ids
      end
    end
  end

  test "same provider identifiers on another connector get an independent parent and grant scope",
       ctx do
    other = ctx.config |> Ecto.reset_fields([:id, :inserted_at, :updated_at]) |> Repo.insert!()

    {:ok, _} =
      People.add_channel(%{
        person_id: ctx.person.id,
        platform: "mattermost",
        channel_identifier: "alice",
        channel_config_id: other.id
      })

    on_exit(fn ->
      Zaq.Channels.Supervisor.stop_bridge_runtime(other, "mattermost_#{other.id}")
    end)

    for config <- [ctx.config, other] do
      assert {{:ok, _}, _} = MattermostHistoryFixture.post(config, "human", false)
    end

    children =
      Repo.all(
        from t in Transcript, where: not is_nil(t.parent_id), order_by: t.channel_config_id
      )

    assert length(children) == 2
    assert Enum.map(children, & &1.channel_config_id) == Enum.sort([ctx.config.id, other.id])
    assert MapSet.size(MapSet.new(Enum.map(children, & &1.permission_resource_id))) == 2

    for child <- children do
      parent = Repo.get!(Transcript, child.parent_id)
      assert parent.channel_config_id == child.channel_config_id
      assert parent.permission_resource_id == child.permission_resource_id
      assert parent.next_position == 0
      assert child.next_position == 1
    end

    assert Repo.aggregate(Message, :count) == 2
    assert Repo.aggregate(TranscriptMessage, :count) == 2
    refute_receive {:history_llm, _}, 200
    refute_received {:history_post, _}
  end

  for server <- [:same, :different] do
    @server server
    test "second connector discovers the same Person on #{@server} server and delivers a reply",
         ctx do
      {:ok, _} = People.update_person(ctx.person, %{email: "alice@example.com"})
      owner = self()

      url =
        if @server == :different do
          {child, endpoint} =
            OpenAIStub.server(&MattermostHistoryFixture.http(&1, &2, owner), owner)

          start_supervised!(Supervisor.child_spec(child, id: :second_mattermost))
          String.trim_trailing(endpoint, "/v1")
        else
          ctx.config.url
        end

      other =
        ctx.config
        |> Ecto.reset_fields([:id, :inserted_at, :updated_at])
        |> Map.put(:url, url)
        |> Repo.insert!()

      on_exit(fn ->
        Zaq.Channels.Supervisor.stop_bridge_runtime(other, "mattermost_#{other.id}")
      end)

      {:ok, _} =
        IncomingMessageRouting.upsert_rule(
          %{channel_config_id: other.id},
          %{routing_mode: :agent, configured_agent_id: ctx.agent.id}
        )

      assert {:error, :not_found} = People.match_by_channel("mattermost", "alice", other.id)
      people_count = Repo.aggregate(Zaq.Accounts.Person, :count)

      assert {:ok, _} =
               Zaq.Permissions.grant(
                 ChannelHistoryResource.for(
                   "mattermost",
                   other.id,
                   "shared-room"
                 ),
                 %{person_id: ctx.person.id, access_rights: ["read"]}
               )

      assert {{:ok, _}, post} = MattermostHistoryFixture.post(other, nil, true)
      assert {:ok, resolved} = People.match_by_channel("mattermost", "alice", other.id)
      assert resolved.id == ctx.person.id
      assert {:ok, original} = People.match_by_channel("mattermost", "alice", ctx.config.id)
      assert original.id == resolved.id
      assert Repo.aggregate(Zaq.Accounts.Person, :count) == people_count
      assert_receive {:history_llm, _}, 5_000
      assert_receive {:history_post, %{"channel_id" => "shared-room"}}, 5_000
      assert_receive {:history_update, %{"message" => "History answer"}}, 5_000
      transcript = Repo.get_by!(Transcript, channel_config_id: other.id)
      answer = await_answer(transcript.id)
      outgoing = await_delivery_event()
      assert outgoing.routing_context.channel_config_id == other.id
      assert outgoing.metadata[:assistant_message_id] == answer.id
      assert Conversations.get_conversation!(answer.conversation_id).person_id == ctx.person.id
      assert Repo.aggregate(TranscriptMessage, :count) == 2

      assert {{:ok, _}, ^post} = MattermostHistoryFixture.post(other, nil, true)
      assert Repo.aggregate(TranscriptMessage, :count) == 2
      assert Repo.aggregate(Zaq.Accounts.Person, :count) == people_count
      refute_receive {:history_llm, _}, 200
      refute_received {:unexpected_history_http, _}
    end
  end

  test "provider root lookup rejects a post from a different room", ctx do
    assert {:error, :unavailable} =
             MattermostAdmin.fetch_room_message(ctx.config, "another-room", "root-human")
  end

  @tag :queue_overflow
  @tag :input_consumption
  @tag timeout: 120_000
  test "real Jido overflow preserves consumption and rejection without extra answers", ctx do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "overflow-root",
               "message" => "@zaq history question"
             })

    assert_receive {:history_llm, _}, 5_000
    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    transcript = Repo.get_by!(Transcript, external_thread_id: "root-human")
    actor = %{person: %{id: ctx.person.id}}
    scope = "history:#{transcript.id}:person:#{ctx.person.id}"
    assert {:ok, {request_id, _state}} = RequestRegistry.find_active(scope, actor)

    receipts =
      for index <- 1..65 do
        input =
          Incoming.new(%{
            content: "@zaq correction #{index}",
            channel_id: "shared-room",
            author_id: "alice",
            message_id: "overflow-#{index}",
            thread_id: "root-human",
            provider: :mattermost,
            person: ctx.person,
            routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
          })
          |> CommunicationBridge.put_conversation_identity()

        assert {:ok, _} = HistoryIngress.capture(input)
        assert {:ok, binding} = Conversations.admit_incoming(input)

        event =
          Zaq.Event.new(
            %{request_id: request_id, content: input.content, conversation_binding: binding},
            :agent,
            actor: actor
          )

        result = Zaq.Agent.Api.handle_event(event, :steer_request, nil)
        record = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)

        if index <= 64 do
          assert %{response: {:ok, _}} = result
          assert record.status == "queued"
        else
          assert %{response: {:error, {:rejected, :queue_full}}} = result
          assert record.status == "unconsumed"
          assert record.outcome["reason"] == "runtime_rejected"
        end

        record.id
      end

    send(worker, :release_history_llm)
    answer = await_answer(transcript.id)
    assert answer.content == "Sealed root answer"
    root_input = Repo.get_by!(Message, external_message_id: "overflow-root")
    root = Repo.get_by!(ExecutionRecord, user_message_id: root_input.id)
    assert root.status == "completed"
    assert root.public_answer_message_id == answer.id

    for {id, index} <- Enum.with_index(receipts, 1) do
      receipt = Repo.get!(ExecutionRecord, id)
      assert receipt.status == if(index <= 64, do: "consumed", else: "unconsumed")
      assert receipt.root_execution_id == root.id
      assert receipt.public_answer_message_id == nil
    end

    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1
    assert Repo.aggregate(from(m in Message, where: m.role == "user"), :count) == 66
  end

  @tag :root_failure
  @tag :input_consumption
  test "real LLM failure seals accepted corrections without claiming consumption or an answer",
       ctx do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(ctx.config, "human", true, %{
               "id" => "failed-root",
               "message" => "@zaq history question"
             })

    assert_receive {:history_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_history_llm) end)
    transcript = Repo.get_by!(Transcript, external_thread_id: "root-human")
    actor = %{person: %{id: ctx.person.id}}
    scope = "history:#{transcript.id}:person:#{ctx.person.id}"
    assert {:ok, {request_id, _}} = RequestRegistry.find_active(scope, actor)

    receipts =
      for index <- 1..2 do
        input =
          Incoming.new(%{
            content: "@zaq failed-run correction #{index}",
            channel_id: "shared-room",
            author_id: "alice",
            message_id: "failed-correction-#{index}",
            thread_id: "root-human",
            provider: :mattermost,
            person: ctx.person,
            routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
          })
          |> CommunicationBridge.put_conversation_identity()

        assert {:ok, _} = HistoryIngress.capture(input)
        assert {:ok, binding} = Conversations.admit_incoming(input)

        event =
          Zaq.Event.new(
            %{request_id: request_id, content: input.content, conversation_binding: binding},
            :agent,
            actor: actor
          )

        assert %{response: {:ok, _}} = Zaq.Agent.Api.handle_event(event, :steer_request, nil)
        receipt = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
        assert receipt.status == "queued"
        receipt.id
      end

    send(worker, :release_history_llm)
    assert_receive {:history_execution_failed, writer}, 5_000
    monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^monitor, :process, ^writer, reason}, 5_000
    assert reason in [:normal, :noproc]
    root_input = Repo.get_by!(Message, external_message_id: "failed-root")
    root = Repo.get_by!(ExecutionRecord, user_message_id: root_input.id)
    assert root.status == "failed"
    assert root.public_answer_message_id == nil

    for id <- receipts do
      receipt = Repo.get!(ExecutionRecord, id)
      assert receipt.status == "unconsumed"
      assert receipt.public_answer_message_id == nil
      assert receipt.root_execution_id == root.id
    end

    assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 0
    assert Repo.aggregate(from(m in Message, where: m.role == "user"), :count) == 3
  end

  defp history_llm_handler(tags, owner) do
    cond do
      tags[:root_failure] ->
        fn _conn, _body -> {400, %{"error" => %{"message" => "Scripted rejection"}}} end

      tags[:queue_overflow] ->
        fn _conn, body ->
          request = Jason.decode!(body)
          {200, MultiAgentOpenAIStub.text_sse("Sealed root answer", request["model"])}
        end

      tags[:input_consumption] ->
        consumption_llm_handler(owner)

      tags[:authorized_execution] ->
        ToolCallingLLMStub.handler(
          routes: [
            %{
              match: &String.contains?(&1, "history question"),
              tool: "add",
              arguments: fn _ -> %{value: 2, amount: 3} end
            }
          ],
          final_response: "History answer"
        )

      true ->
        nil
    end
  end

  defp assert_rejected_control_receipt(ctx, state, actor) do
    # A stale registry handle must be refused by the real active Jido runtime.
    # Exercise the queue -> runtime rejection -> receipt persistence path without
    # substituting Factory, RequestControl, NodeRouter or the execution store.
    stale_id = "stale-control-#{System.unique_integer([:positive])}"
    assert :ok = RequestRegistry.put(stale_id, state)

    input =
      Incoming.new(%{
        content: "@zaq Rejected correction",
        channel_id: "shared-room",
        author_id: "alice",
        message_id: "rejected-correction",
        thread_id: "root-human",
        provider: :mattermost,
        person: ctx.person,
        routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)

    event =
      Zaq.Event.new(
        %{request_id: stale_id, content: input.content, conversation_binding: binding},
        :agent,
        actor: actor
      )

    assert %{response: {:error, _}} = Zaq.Agent.Api.handle_event(event, :steer_request, nil)
    receipt = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
    assert receipt.status == "unconsumed"
    assert receipt.outcome["reason"] == "runtime_rejected"
    assert receipt.public_answer_message_id == nil
    assert :ok = RequestRegistry.delete(stale_id)
  end

  defp consumption_llm_handler(owner) do
    state = start_supervised!({Agent, fn -> :initial end}, id: make_ref())
    args = %{"value" => 2, "amount" => 3}
    call_id = "receipt-call-#{System.unique_integer([:positive])}"

    fn _conn, body ->
      request = Jason.decode!(body)

      Agent.get_and_update(state, fn
        :initial ->
          send(owner, {:llm_tool_call, "add", args})

          response =
            MultiAgentOpenAIStub.tool_call_sse("add", args,
              model: request["model"],
              call_id: call_id
            )

          {{200, response}, {:continuation, request["input"]}}

        {:continuation, initial} ->
          assert Enum.take(request["input"], length(initial)) == initial
          [call, output, correction] = Enum.drop(request["input"], length(initial))
          assert call["type"] == "function_call"
          assert call["call_id"] == call_id
          assert call["name"] == "add"
          assert Jason.decode!(call["arguments"]) == args
          assert output["type"] == "function_call_output"
          assert output["call_id"] == call_id

          assert MultiAgentOpenAIStub.latest_user_message(%{"input" => [correction]}) ==
                   "@zaq Retain the arithmetic tool result"

          [result] = MultiAgentOpenAIStub.tool_results(request)
          send(owner, {:llm_tool_result, "add", result.output})
          {{200, MultiAgentOpenAIStub.text_sse("History answer", request["model"])}, :done}
      end)
    end
  end

  defp await_delivery_event do
    receive do
      {:node_router_event, %Zaq.Event{opts: opts, request: %Outgoing{} = outgoing}} ->
        if opts[:action] == :deliver_outgoing, do: outgoing, else: await_delivery_event()
    after
      5_000 -> flunk("no real Engine delivery event was observed")
    end
  end

  defp observe_history_commit(owner) do
    handler = {__MODULE__, owner}

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        observe_history_query(metadata, owner, handler)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp observe_history_query(metadata, owner, handler) do
    if self() != owner do
      cond do
        failed_execution_query?(metadata) ->
          Process.put({handler, :failed_execution}, true)

        queued_record_query?(metadata) ->
          Process.put({handler, :receipt}, true)

        confirmed_placement_query?(metadata) ->
          Process.put(handler, true)

        metadata.query == "commit" ->
          notify_history_commit(owner, handler)

        true ->
          :ok
      end
    end
  end

  defp notify_history_commit(owner, handler) do
    flags = [
      {handler, {:history_placement_committed, self()}},
      {{handler, :receipt}, :history_input_queued},
      {{handler, :failed_execution}, {:history_execution_failed, self()}}
    ]

    Enum.each(flags, fn {key, message} ->
      if Process.delete(key), do: send(owner, message)
    end)
  end

  defp failed_execution_query?(metadata),
    do:
      metadata[:source] == "execution_records" and String.starts_with?(metadata.query, "UPDATE") and
        "failed" in (metadata[:cast_params] || [])

  defp queued_record_query?(metadata),
    do:
      metadata[:source] == "execution_records" and String.starts_with?(metadata.query, "UPDATE") and
        "queued" in (metadata[:cast_params] || [])

  defp confirmed_placement_query?(metadata),
    do:
      metadata[:source] == "transcript_messages" and String.starts_with?(metadata.query, "INSERT") and
        "provider_confirmed" in (metadata[:cast_params] || [])

  defp await_answer(transcript_id) do
    assert_receive {:history_placement_committed, writer}, 5_000
    monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^monitor, :process, ^writer, reason}, 5_000
    assert reason in [:normal, :noproc]

    Repo.one!(
      from m in Message,
        join: p in TranscriptMessage,
        on: p.message_id == m.id,
        where: p.transcript_id == ^transcript_id and m.role == "assistant",
        select: m
    )
  end
end
