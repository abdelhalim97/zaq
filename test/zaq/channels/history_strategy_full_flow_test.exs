defmodule Zaq.Channels.HistoryStrategyFullFlowTest do
  @moduledoc """
  Production-path history acceptance, without pre-granted channel permissions.

  Only the remote Mattermost/OpenAI servers and the SMTP transport are replaced.
  Each surface gets its own execution so missing accounting cannot hide a broken
  persisted modal (and a broken modal cannot hide delivery/replay regressions).
  """

  use ZaqWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Agent.RequestRegistry
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.ImapAdapter
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations

  alias Zaq.Engine.Conversations.{
    ExecutionRecord,
    Message,
    Transcript,
    TranscriptHistory,
    TranscriptMessage
  }

  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo

  alias Zaq.TestSupport.{
    MattermostHistoryFixture,
    MultiAgentOpenAIStub,
    OpenAIStub,
    ToolCallingLLMStub
  }

  @shared_room "abcdefghijklmnopqrstuvwx12"

  @runtime_keys [
    :channels,
    :chat_bridge_pipeline_module,
    :chat_bridge_node_router_module,
    :chat_bridge_accounts_module,
    :chat_bridge_permissions_module,
    :chat_bridge_supervisor_module,
    :chat_bridge_chat_module,
    :email_bridge_pipeline_module,
    :email_bridge_node_router_module,
    :email_bridge_smtp_module,
    :pipeline_hooks_module
  ]

  setup tags do
    Zaq.DataCase.isolate_event_registry()
    owner = self()
    previous = Map.new(@runtime_keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(@runtime_keys, &Application.delete_env(:zaq, &1))

    Application.put_env(:zaq, :channels, %{
      mattermost: %{
        bridge: JidoChatBridge,
        adapter: Jido.Chat.Mattermost.Adapter,
        ingress_mode: :webhook
      },
      email: %{bridge: EmailBridge, adapter: ImapAdapter, message_format: :html}
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)

    llm =
      cond do
        tags[:steering_phase] ->
          steering_llm_handler(owner, tags.steering_phase)

        tags[:concurrent_people] ->
          concurrent_llm_handler(owner)

        tags[:active_update] ->
          active_llm_handler(owner)

        true ->
          ToolCallingLLMStub.handler(
            routes: [
              %{
                match: fn text ->
                  String.contains?(text, "history question") or
                    String.contains?(text, "Active update evidence")
                end,
                tool: "add",
                arguments: fn _ -> %{value: 2, amount: 3} end
              }
            ],
            final_response: "History answer",
            max_interactions: 2
          )
      end

    handler = fn conn, body ->
      if conn.request_path == "/v1/responses" do
        send(owner, {:strategy_llm, Jason.decode!(body)})
        llm.(conn, body)
      else
        case conn.request_path do
          "/api/v4/channels/" <> @shared_room <> "/members" ->
            {200, [%{"user_id" => "alice"}, %{"user_id" => "bob"}]}

          "/api/v4/posts/root-human" ->
            {200,
             %{
               "id" => "root-human",
               "user_id" => "bob",
               "channel_id" => @shared_room,
               "message" => "Authorized project root",
               "root_id" => "",
               "create_at" => 1_700_000_000_000
             }}

          _ ->
            MattermostHistoryFixture.http(conn, body, owner)
            |> unique_post_receipt(conn)
        end
      end
    end

    {server, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(server)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Strategy acceptance #{System.unique_integer([:positive])}",
        description: "",
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        model_max_context_tokens: 20_000,
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys:
          if(tags[:steering_phase], do: ["basic.sleep"], else: ["arithmetic.add"]),
        conversation_enabled: true,
        active: true,
        advanced_options: %{"stream" => false}
      })

    config = connector(tags.strategy, endpoint)

    assert {:ok, _} =
             IncomingMessageRouting.upsert_rule(
               %{channel_config_id: config.id},
               %{routing_mode: :agent, configured_agent_id: agent.id}
             )

    on_exit(fn ->
      ServerManager.stop_server(agent)

      if config.provider == "mattermost",
        do: Zaq.Channels.Supervisor.stop_bridge_runtime(config, "mattermost_#{config.id}")
    end)

    observe_committed_delivery(owner)
    %{config: config, agent: agent}
  end

  defp unique_post_receipt({201, payload}, %{method: "POST", request_path: "/api/v4/posts"}) do
    {201, Map.put(payload, "id", "bot-response-#{System.unique_integer([:positive])}")}
  end

  defp unique_post_receipt(response, _conn), do: response

  for strategy <- [:shared_refreshed, :replicated] do
    @tag strategy: strategy
    @tag :concurrent_people
    test "#{strategy} concurrent People retain separate runtimes, authority and answer owners",
         ctx do
      {_replay, external_id} = ingress(ctx)
      assert_receive {:concurrent_initial, "alice", alice_input, alice_worker}, 5_000
      on_exit(fn -> send(alice_worker, :release_strategy_llm) end)
      assert Jason.encode!(alice_input["input"]) =~ "history question"
      bob_id = concurrent_bob_ingress(ctx)
      assert_receive {:concurrent_initial, "bob", bob_input, bob_worker}, 5_000
      on_exit(fn -> send(bob_worker, :release_strategy_llm) end)
      refute Jason.encode!(bob_input["input"]) =~ "FORBIDDEN_RECIPIENT_ONLY"

      roots = Enum.map([external_id, bob_id], &Repo.get_by!(Message, external_message_id: &1))

      [alice_execution, bob_execution] =
        Enum.map(roots, &Repo.get_by!(ExecutionRecord, user_message_id: &1.id))

      refute alice_execution.person_id == bob_execution.person_id
      refute alice_execution.id == bob_execution.id

      states =
        Enum.zip(roots, [alice_execution, bob_execution])
        |> Enum.map(fn {input, execution} ->
          transcript = owner_transcript(input, execution.person_id)
          scope = "history:#{transcript.id}:person:#{execution.person_id}"
          actor = %{person: %{id: execution.person_id}}
          assert {:ok, {request_id, state}} = RequestRegistry.find_active(scope, actor)
          assert state.actor.person.id == execution.person_id
          {request_id, state, transcript}
        end)

      [{alice_request, alice_state, alice_transcript}, {bob_request, bob_state, bob_transcript}] =
        states

      refute alice_request == bob_request
      refute alice_state.runtime_pid == bob_state.runtime_pid

      if ctx.strategy == :replicated do
        refute alice_transcript.id == bob_transcript.id

        assert {:error, :unauthorized} =
                 TranscriptHistory.list(
                   People.get_person!(alice_execution.person_id),
                   bob_transcript.id,
                   []
                 )

        recipient_only_ingress(ctx.config)
      else
        assert alice_transcript.id == bob_transcript.id
      end

      send(alice_worker, :release_strategy_llm)
      send(bob_worker, :release_strategy_llm)

      for owner <- ["alice", "bob"] do
        assert_receive {:concurrent_continuation, ^owner, request}, 5_000
        refute Jason.encode!(request["input"]) =~ "FORBIDDEN_RECIPIENT_ONLY"
        [result] = MultiAgentOpenAIStub.tool_results(request)
        assert result.call_id == "concurrent-#{owner}"
        assert result.output == %{"ok" => true, "result" => %{"result" => 5.0}}
      end

      await_committed_delivery()
      await_committed_delivery()

      for {owner, execution} <- [{"alice", alice_execution}, {"bob", bob_execution}] do
        completed = Repo.get!(ExecutionRecord, execution.id)
        assert completed.status == "completed"
        assert completed.person_id == execution.person_id
        assert completed.root_execution_id == nil

        assert Repo.get!(Message, completed.public_answer_message_id).content ==
                 "History answer #{owner}"
      end

      answers =
        Repo.all(
          from e in ExecutionRecord,
            where: e.status == "completed",
            select: e.public_answer_message_id
        )

      assert length(Enum.uniq(answers)) == 2
      refute_receive {:concurrent_initial, _, _, _}, 200
      refute_received {:unexpected_history_http, _}
    end
  end

  defp concurrent_llm_handler(owner) do
    fn _conn, body ->
      request = Jason.decode!(body)
      concurrent_llm_response(MultiAgentOpenAIStub.tool_results(request), request, owner)
    end
  end

  defp concurrent_llm_response([], request, owner) do
    person =
      if MultiAgentOpenAIStub.latest_user_message(request) =~ "history question Bob",
        do: "bob",
        else: "alice"

    send(owner, {:concurrent_initial, person, request, self()})

    receive do
      :release_strategy_llm -> :ok
    after
      10_000 -> flunk("concurrent LLM barrier was not released")
    end

    {200,
     MultiAgentOpenAIStub.tool_call_sse("add", %{value: 2, amount: 3},
       model: request["model"],
       call_id: "concurrent-#{person}"
     )}
  end

  defp concurrent_llm_response([%{call_id: "concurrent-" <> person}], request, owner) do
    send(owner, {:concurrent_continuation, person, request})
    {200, MultiAgentOpenAIStub.text_sse("History answer #{person}", request["model"])}
  end

  defp concurrent_bob_ingress(%{strategy: :replicated, config: config}) do
    payload =
      email_payload(
        "history question Bob",
        "bob-request@example.com",
        "References: <strategy-input@example.com>"
      )
      |> Map.put(:from, %{address: "bob@example.com", name: "Bob"})
      |> Map.update!(:raw_header, fn header ->
        header
        |> String.replace("From: Alice <alice@example.com>", "From: Bob <bob@example.com>")
        |> String.replace(
          "To: ZAQ <bot@example.com>, Bob <bob@example.com>",
          "To: ZAQ <bot@example.com>, Alice <alice@example.com>"
        )
      end)

    assert :ok = EmailBridge.from_listener(config, payload, mailbox: "INBOX")
    "<bob-request@example.com>"
  end

  defp concurrent_bob_ingress(%{config: config}) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, "human", true, %{
               "id" => "bob-request",
               "channel_id" => @shared_room,
               "user_id" => "bob",
               "message" => "@zaq history question Bob"
             })

    "bob-request"
  end

  defp recipient_only_ingress(config) do
    payload = %{
      from: %{address: "carol@example.com", name: "Carol"},
      body_text: "FORBIDDEN_RECIPIENT_ONLY",
      raw_header:
        "To: bot@example.com\r\nMessage-ID: <carol-only@example.com>\r\nReferences: <strategy-input@example.com>\r\nAuto-Submitted: auto-replied"
    }

    assert ImapAdapter.to_internal(payload, %{}).metadata["email"]["automatic_reply"] == true
    assert :ok = EmailBridge.from_listener(config, payload, mailbox: "INBOX")
    carol_only = Repo.get_by!(Message, external_message_id: "<carol-only@example.com>")

    assert Repo.aggregate(
             from(p in TranscriptMessage, where: p.message_id == ^carol_only.id),
             :count
           ) == 1
  end

  for {strategy, update} <- [
        {:shared, :owner_followup},
        {:shared_refreshed, :owner_followup},
        {:shared_refreshed, :other_author},
        {:direct, :owner_followup},
        {:replicated, :owner_followup}
      ] do
    @tag strategy: strategy
    @tag active_update: update
    test "#{strategy} #{update} updates the actual running request without transferring ownership",
         ctx do
      {_replay, external_id} = ingress(ctx)
      assert_receive {:strategy_llm, initial}, 5_000
      assert_receive {:strategy_llm_barrier, worker}, 5_000
      on_exit(fn -> send(worker, :release_strategy_llm) end)
      root = Repo.get_by!(Message, external_message_id: external_id)
      execution = Repo.get_by!(ExecutionRecord, user_message_id: root.id)
      person_id = execution.person_id
      actor = %{person: %{id: person_id}}
      transcript = owner_transcript(root, person_id)
      scope = "history:#{transcript.id}:person:#{person_id}"
      assert {:ok, {request_id, state}} = RequestRegistry.find_active(scope, actor)
      assert state.actor.person.id == person_id
      assert state.agent.id == ctx.agent.id
      assert Process.alive?(state.runtime_pid)
      observe_native_input(state.consumer_pid)

      update_id = active_ingress(ctx)
      if ctx.active_update == :owner_followup, do: assert_receive(:strategy_input_queued, 5_000)
      update_message = Repo.get_by!(Message, external_message_id: update_id)

      if ctx.active_update == :owner_followup do
        receipt = Repo.get_by!(ExecutionRecord, user_message_id: update_message.id)
        assert receipt.status == "queued"
        assert receipt.root_execution_id == execution.id
        assert receipt.public_answer_message_id == nil
      else
        assert update_message.author_id == "bob"
        assert Repo.get_by(ExecutionRecord, user_message_id: update_message.id) == nil
      end

      assert {:ok, {^request_id, current}} = RequestRegistry.find_active(scope, actor)
      assert current.runtime_pid == state.runtime_pid
      assert current.actor.person.id == person_id
      send(worker, :release_strategy_llm)
      assert_receive {:strategy_llm, continuation}, 5_000
      encoded = Jason.encode!(continuation["input"])
      assert length(Regex.scan(~r/Active update evidence/, encoded)) == 1
      assert length(Regex.scan(~r/history question/, encoded)) == 1
      assert Enum.take(continuation["input"], 1) == Enum.take(initial["input"], 1)

      [tool_result] = MultiAgentOpenAIStub.tool_results(continuation)
      assert tool_result.call_id == "active-history-call"
      assert tool_result.output == %{"ok" => true, "result" => %{"result" => 5.0}}

      if ctx.active_update == :other_author,
        do: assert(encoded =~ "bob (bob): Active update evidence")

      await_committed_delivery()
      completed = Repo.get!(ExecutionRecord, execution.id)
      assert completed.status == "completed"
      assert completed.person_id == person_id
      answer = Repo.get!(Message, completed.public_answer_message_id)
      assert answer.content == "History answer"
      assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1

      if ctx.active_update == :owner_followup do
        receipt = Repo.get_by!(ExecutionRecord, user_message_id: update_message.id)
        assert receipt.status == "consumed"
        assert receipt.root_execution_id == completed.id
        assert receipt.public_answer_message_id == nil
        assert_native_consumption(state.consumer_pid, request_id, update_message.id)
      end

      assert_transport(ctx.strategy)
      refute_receive {:strategy_llm, _}, 200
      refute_received {:unexpected_history_http, _}
    end
  end

  for strategy <- [:shared, :shared_refreshed, :direct, :replicated],
      surface <- [
        :lifecycle,
        :measurements,
        :modal_traces,
        :modal_measurements,
        :modal_authorization
      ] do
    @tag strategy: strategy
    @tag surface: surface
    test "#{strategy} real ingress proves #{surface} without pre-granted access", ctx do
      result = execute_journey(ctx)

      case ctx.surface do
        :lifecycle -> assert_lifecycle(ctx, result)
        :measurements -> assert_measurements(result)
        :modal_traces -> assert_persisted_modal(ctx.conn, result, :traces)
        :modal_measurements -> assert_persisted_modal(ctx.conn, result, :measurements)
        :modal_authorization -> assert_modal_authorization(ctx.conn, result)
      end

      refute_received {:llm_stub_error, _}
      refute_received {:unexpected_history_http, _}
    end
  end

  for phase <- [:first_sleep, :second_sleep, :silent_model_wait, :reasoning_stream, :text_stream] do
    @tag strategy: :shared
    @tag active_update: :owner_followup
    @tag steering_phase: phase
    test "same-Person Spanish correction during #{phase} stays in one native execution", ctx do
      registry = Process.whereis(RequestRegistry)
      :erlang.trace(registry, true, [:receive, {:tracer, self()}])

      on_exit(fn ->
        if Process.alive?(registry), do: :erlang.trace(registry, false, [:receive])
      end)

      steering_ingress(ctx.config)
      assert_receive {:strategy_llm, initial}, 5_000
      root = Repo.get_by!(Message, external_message_id: "steering-root")
      execution = Repo.get_by!(ExecutionRecord, user_message_id: root.id)
      actor = %{person: %{id: execution.person_id}}
      transcript = owner_transcript(root, execution.person_id)
      scope = "history:#{transcript.id}:person:#{execution.person_id}"

      {request_id, state, worker} =
        await_steering_phase(ctx.steering_phase, registry, scope, actor)

      :erlang.trace(registry, false, [:receive])
      observe_native_input(state.consumer_pid)

      spanish_correction(ctx.config)

      assert_receive :strategy_input_queued, 5_000
      update = Repo.get_by!(Message, external_message_id: "spanish-correction")
      receipt = Repo.get_by!(ExecutionRecord, user_message_id: update.id)
      assert receipt.root_execution_id == execution.id
      assert receipt.public_answer_message_id == nil
      if worker, do: send(worker, :release_steering_llm)

      assert_receive {:steering_final_model, final_request}, 20_000

      for _ <- 1..if(ctx.steering_phase == :second_sleep, do: 1, else: 2) do
        assert_receive {:strategy_llm, _}, 5_000
      end

      encoded = Jason.encode!(final_request["input"])
      assert length(Regex.scan(~r/actually in Spanish/, encoded)) == 1
      assert length(Regex.scan(~r/finally say Hi in japanese/, encoded)) == 1
      assert Enum.take(final_request["input"], 1) == Enum.take(initial["input"], 1)
      results = MultiAgentOpenAIStub.tool_results(final_request)
      assert Enum.map(results, & &1.call_id) == ["sleep-one", "sleep-two"]
      assert Enum.all?(results, &(&1.output["ok"] == true))
      await_committed_delivery()

      completed = Repo.get!(ExecutionRecord, execution.id)
      assert completed.status == "completed"
      assert completed.person_id == execution.person_id
      assert Repo.get!(Message, completed.public_answer_message_id).content == "Hola"

      assert Repo.aggregate(
               from(e in ExecutionRecord, where: is_nil(e.root_execution_id)),
               :count
             ) == 1

      assert Repo.aggregate(from(m in Message, where: m.role == "assistant"), :count) == 1
      assert Repo.get!(ExecutionRecord, receipt.id).status == "consumed"
      assert_native_consumption(state.consumer_pid, request_id, update.id)

      if Process.alive?(state.consumer_pid),
        do: :erlang.trace(state.consumer_pid, false, [:receive])

      assert completed.outcome["measurements"]["tool_call_count"] == 2
      assert completed.outcome["measurements"]["llm_call_count"] == 3
      assert {:error, :not_found} = RequestRegistry.find_active(scope, actor)
      assert_transport(:shared, nil, "Hola")
      refute_receive {:strategy_llm, _}, 200
      refute_received {:unexpected_history_http, _}
    end
  end

  @tag strategy: :shared
  @tag steering_phase: :terminal_followup
  test "a correction after native completion becomes a new answer-owning followup", ctx do
    steering_ingress(ctx.config)
    assert_receive {:strategy_llm, _}, 5_000
    assert_receive {:steering_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_steering_llm) end)
    root = Repo.get_by!(Message, external_message_id: "steering-root")
    execution = Repo.get_by!(ExecutionRecord, user_message_id: root.id)
    actor = %{person: %{id: execution.person_id}}
    transcript = owner_transcript(root, execution.person_id)
    scope = "history:#{transcript.id}:person:#{execution.person_id}"
    assert {:ok, {_id, state}} = RequestRegistry.find_active(scope, actor)
    send(worker, :release_steering_llm)
    assert_receive {:steering_final_model, _}, 5_000
    await_committed_delivery()

    assert {:ok, %{status: :completed}} =
             Jido.AgentServer.await_completion(state.runtime_pid,
               status_path: [:__strategy__, :status],
               timeout: 5_000
             )

    assert {:error, :not_found} = RequestRegistry.find_active(scope, actor)
    assert_transport(:shared, nil, "こんにちは")

    spanish_correction(ctx.config)
    assert_receive {:steering_followup_model, followup}, 5_000
    assert MultiAgentOpenAIStub.latest_user_message(followup) =~ "actually in Spanish"
    await_committed_delivery()
    update = Repo.get_by!(Message, external_message_id: "spanish-correction")
    second = Repo.get_by!(ExecutionRecord, user_message_id: update.id)
    assert second.status == "completed"
    assert second.root_execution_id == nil
    assert second.person_id == execution.person_id
    assert Repo.get!(Message, second.public_answer_message_id).content == "Hola"

    assert second.public_answer_message_id !=
             Repo.get!(ExecutionRecord, execution.id).public_answer_message_id

    assert Repo.aggregate(from(e in ExecutionRecord, where: is_nil(e.root_execution_id)), :count) ==
             2

    assert_transport(:shared, nil, "Hola")
    refute_received :strategy_input_queued
  end

  defp steering_ingress(config) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, nil, true, %{
               "id" => "steering-root",
               "channel_id" => @shared_room,
               "message" =>
                 "@zaq local sleep for 10 seconds, then sleep again for 5 seconds and finally say Hi in japanese"
             })
  end

  defp spanish_correction(config) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, nil, true, %{
               "id" => "spanish-correction",
               "channel_id" => @shared_room,
               "message" => "@zaq actually in Spanish"
             })
  end

  defp await_steering_phase(phase, registry, scope, actor) do
    {status, worker} =
      case phase do
        :first_sleep ->
          {:tool_running, nil}

        :second_sleep ->
          assert_receive {:strategy_llm, _}, 15_000
          {:tool_running, nil}

        :silent_model_wait ->
          assert_receive {:steering_llm_barrier, pid}, 5_000
          on_exit(fn -> send(pid, :release_steering_llm) end)
          {:tool_completed, pid}

        _ ->
          assert_receive {:steering_llm_barrier, pid}, 5_000
          on_exit(fn -> send(pid, :release_steering_llm) end)
          {:streaming, pid}
      end

    call_id = if phase == :second_sleep, do: "sleep-two", else: "sleep-one"
    await_registry_phase(registry, status, call_id)
    assert {:ok, {id, state}} = RequestRegistry.find_active(scope, actor)
    assert state.status == status
    {id, state, worker}
  end

  defp await_registry_phase(registry, status, call_id) do
    assert_receive {:trace, ^registry, :receive,
                    {:"$gen_call", _, {:put, _id, %{status: ^status} = attrs}}},
                   15_000

    :sys.get_state(registry)

    if status == :tool_running and not Enum.any?(attrs.tool_calls, &(&1["id"] == call_id)),
      do: await_registry_phase(registry, status, call_id)
  end

  defp steering_llm_handler(owner, phase) do
    turn = :atomics.new(1, [])

    fn conn, body ->
      request = Jason.decode!(body)
      steering_model_turn(:atomics.add_get(turn, 1, 1), conn, request, owner, phase)
    end
  end

  defp steering_model_turn(1, conn, request, owner, phase) do
    if phase == :terminal_followup, do: steering_model_barrier(owner)
    duration = if phase == :first_sleep, do: 10_000, else: 1

    response =
      MultiAgentOpenAIStub.tool_call_sse("sleep_action", %{duration_ms: duration},
        model: request["model"],
        call_id: "sleep-one"
      )

    if phase in [:reasoning_stream, :text_stream],
      do: streaming_steering_response(conn, response, owner, phase),
      else: {200, response}
  end

  defp steering_model_turn(2, _conn, request, owner, phase) do
    if phase == :silent_model_wait, do: steering_model_barrier(owner)
    duration = if phase in [:first_sleep, :second_sleep], do: 5_000, else: 1

    {200,
     MultiAgentOpenAIStub.tool_call_sse("sleep_action", %{duration_ms: duration},
       model: request["model"],
       call_id: "sleep-two"
     )}
  end

  defp steering_model_turn(3, _conn, request, owner, _phase) do
    send(owner, {:steering_final_model, request})

    answer =
      if Jason.encode!(request["input"]) =~ "actually in Spanish", do: "Hola", else: "こんにちは"

    {200, MultiAgentOpenAIStub.text_sse(answer, request["model"])}
  end

  defp steering_model_turn(4, _conn, request, owner, :terminal_followup) do
    send(owner, {:steering_followup_model, request})
    {200, MultiAgentOpenAIStub.text_sse("Hola", request["model"])}
  end

  defp steering_model_turn(_turn, _conn, _request, _owner, _phase),
    do: {500, %{"error" => "unexpected steering model turn"}}

  defp streaming_steering_response(conn, response, owner, phase) do
    event =
      if phase == :reasoning_stream,
        do: "response.reasoning.delta",
        else: "response.output_text.delta"

    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    assert {:ok, conn} =
             Plug.Conn.chunk(
               conn,
               "event: #{event}\ndata: #{Jason.encode!(%{delta: "Considering the greeting. "})}\n\n"
             )

    steering_model_barrier(owner)
    assert {:ok, conn} = Plug.Conn.chunk(conn, response)
    conn
  end

  defp steering_model_barrier(owner) do
    send(owner, {:steering_llm_barrier, self()})

    receive do
      :release_steering_llm -> :ok
    after
      10_000 -> flunk("steering model barrier was not released")
    end
  end

  defp execute_journey(ctx) do
    {replay, external_id} = ingress(ctx)

    # Capture is not admission. A factual transcript must not be mistaken for
    # evidence that a provider-derived sender was authorized to run the agent.
    assert_receive {:strategy_llm, initial}, 5_000
    input = Repo.get_by!(Message, external_message_id: external_id)
    assert {:ok, _} = Ecto.UUID.cast(input.id)
    assert Jason.encode!(initial["input"]) =~ "history question"

    if ctx.strategy == :shared_refreshed do
      encoded = Jason.encode!(initial["input"])
      assert length(Regex.scan(~r/Authorized project root/, encoded)) == 1
      assert encoded =~ "bob"
    end

    assert_receive {:llm_tool_call, "add", %{"value" => 2, "amount" => 3}}, 5_000
    assert_receive {:llm_tool_result, "add", result}, 5_000
    assert result == %{"ok" => true, "result" => %{"result" => 5.0}}
    assert_receive {:strategy_llm, continuation}, 5_000
    assert Enum.any?(continuation["input"], &(&1["type"] == "function_call_output"))
    await_committed_delivery()

    execution = Repo.get_by!(ExecutionRecord, user_message_id: input.id)
    assert execution.status == "completed"
    answer = Repo.get!(Message, execution.public_answer_message_id)
    assert answer.content == "History answer"
    assert {:ok, _} = Ecto.UUID.cast(answer.id)
    assert answer.trace == []
    assert answer.prompt_tokens == nil
    refute Map.has_key?(answer.metadata, "measurements")

    transcript = owner_transcript(input, execution.person_id)

    expected_strategy =
      if ctx.strategy == :shared_refreshed, do: "shared", else: Atom.to_string(ctx.strategy)

    assert transcript.strategy == expected_strategy
    assert Conversations.get_conversation!(input.conversation_id).person_id == execution.person_id

    %{
      input: input,
      answer: answer,
      execution: execution,
      transcript: transcript,
      replay: replay,
      initial: initial,
      continuation: continuation
    }
  end

  defp owner_transcript(input, person_id) do
    Repo.one!(
      from t in Transcript,
        join: p in TranscriptMessage,
        on: p.transcript_id == t.id,
        where:
          p.message_id == ^input.id and
            (is_nil(t.owner_person_id) or t.owner_person_id == ^person_id)
    )
  end

  defp await_committed_delivery do
    assert_receive {:strategy_delivery_committed, writer}, 5_000

    if writer != self() do
      monitor = Process.monitor(writer)
      assert_receive {:DOWN, ^monitor, :process, ^writer, reason}, 5_000
      assert reason in [:normal, :noproc]
    end
  end

  defp observe_native_input(consumer) do
    # Confidential Engine consumption events intentionally do not enter PubSub.
    # Observe the exact consumer's native mailbox instead of replacing its router
    # or feeding StreamEvents a fabricated input_injected event.
    :erlang.trace(consumer, true, [:receive, {:tracer, self()}])

    on_exit(fn ->
      if Process.alive?(consumer), do: :erlang.trace(consumer, false, [:receive])
    end)
  end

  defp assert_native_consumption(consumer, request_id, input_id) do
    assert_receive {:trace, ^consumer, :receive,
                    {_tag,
                     %Jido.AI.Runtime.Event{
                       request_id: ^request_id,
                       kind: :input_injected,
                       data: data
                     }}},
                   5_000

    assert data.refs.message_id == input_id
  end

  defp active_llm_handler(owner) do
    turn = :atomics.new(1, [])

    fn _conn, body ->
      request = Jason.decode!(body)

      case :atomics.add_get(turn, 1, 1) do
        1 ->
          send(owner, {:strategy_llm_barrier, self()})

          receive do
            :release_strategy_llm -> :ok
          after
            10_000 -> flunk("active request LLM barrier was not released")
          end

          {200,
           MultiAgentOpenAIStub.tool_call_sse("add", %{value: 2, amount: 3},
             model: request["model"],
             call_id: "active-history-call"
           )}

        2 ->
          {200, MultiAgentOpenAIStub.text_sse("History answer", request["model"])}

        _ ->
          send(owner, :unexpected_active_model_turn)
          {500, %{"error" => "unexpected active request turn"}}
      end
    end
  end

  defp active_ingress(%{strategy: :replicated, config: config}) do
    payload =
      email_payload(
        "Active update evidence",
        "active-update@example.com",
        "References: <strategy-input@example.com>"
      )

    assert :ok = EmailBridge.from_listener(config, payload, mailbox: "INBOX")
    "<active-update@example.com>"
  end

  defp active_ingress(%{strategy: :direct, config: config}) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.direct_post(config, %{
               "id" => "active-update",
               "message" => "Active update evidence"
             })

    "active-update"
  end

  defp active_ingress(%{strategy: :shared, config: config}) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, nil, true, %{
               "id" => "active-update",
               "channel_id" => @shared_room,
               "message" => "@zaq Active update evidence"
             })

    "active-update"
  end

  defp active_ingress(%{config: config, active_update: update}) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, "human", update == :owner_followup, %{
               "id" => "active-update",
               "channel_id" => @shared_room,
               "user_id" => if(update == :other_author, do: "bob", else: "alice"),
               "message" =>
                 if(update == :other_author,
                   do: "Active update evidence",
                   else: "@zaq Active update evidence"
                 )
             })

    "active-update"
  end

  defp assert_lifecycle(ctx, result) do
    %{transcript: transcript, input: input, answer: answer, execution: execution} = result
    placements = placements(transcript.id)
    assert Enum.map(placements, & &1.message_id) == [input.id, answer.id]
    assert Enum.map(placements, & &1.position) == Enum.sort(Enum.map(placements, & &1.position))
    assert List.last(placements).provenance == "provider_confirmed"
    assert length(execution.tool_results) == 1
    assert execution.trace_entries != []
    assert_transport(ctx.strategy)
    assert_recipient_isolation(ctx, result)

    ids = Repo.all(from m in Message, order_by: m.id, select: m.id)
    execution_ids = Repo.all(from e in ExecutionRecord, order_by: e.id, select: e.id)
    count = Repo.aggregate(TranscriptMessage, :count)
    result.replay.()
    assert Repo.all(from m in Message, order_by: m.id, select: m.id) == ids
    assert Repo.all(from e in ExecutionRecord, order_by: e.id, select: e.id) == execution_ids
    assert Repo.aggregate(TranscriptMessage, :count) == count
    refute_receive {:strategy_llm, _}, 200
    refute_received {:email, _}
    refute_received {:history_post, _}
    assert_warm_followup(ctx, result)
  end

  defp assert_warm_followup(ctx, result) do
    external_id = active_ingress(Map.put(ctx, :active_update, :owner_followup))
    assert_receive {:strategy_llm, next}, 5_000
    encoded = Jason.encode!(next["input"])
    assert length(Regex.scan(~r/history question/, encoded)) == 1
    assert length(Regex.scan(~r/History answer/, encoded)) == 1
    assert length(Regex.scan(~r/Active update evidence/, encoded)) == 1
    assert_receive {:llm_tool_call, "add", %{"value" => 2, "amount" => 3}}, 5_000

    assert_receive {:llm_tool_result, "add", %{"ok" => true, "result" => %{"result" => 5.0}}},
                   5_000

    assert_receive {:strategy_llm, continuation}, 5_000
    assert length(MultiAgentOpenAIStub.tool_results(continuation)) == 2
    await_committed_delivery()
    followup = Repo.get_by!(Message, external_message_id: external_id)
    execution = Repo.get_by!(ExecutionRecord, user_message_id: followup.id)
    assert execution.status == "completed"
    assert execution.person_id == result.execution.person_id
    assert execution.root_execution_id == nil
    assert execution.public_answer_message_id != result.answer.id
    assert Repo.get!(Message, execution.public_answer_message_id).content == "History answer"
    assert owner_transcript(followup, execution.person_id).id == result.transcript.id
    assert_transport(ctx.strategy, "<active-update@example.com>")
  end

  defp assert_measurements(%{execution: execution}) do
    assert execution.usage["prompt_tokens"] == 10
    assert execution.usage["completion_tokens"] == 2
    assert execution.usage["total_tokens"] == 12
    assert execution.trace_entries != []
    assert length(execution.tool_results) == 1
    measurements = execution.outcome["measurements"]

    assert is_map(measurements),
           "completed private execution must retain the runtime measurements"

    assert is_integer(measurements["latency_ms"]) and measurements["latency_ms"] >= 0
    assert measurements["turn_count"] == 2
    assert measurements["llm_call_count"] == 2
    assert measurements["tool_call_count"] == 1
  end

  defp assert_persisted_modal(conn, result, surface) do
    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: admin.id})
    path = "/bo/channels/history/#{result.transcript.id}"

    # Two fresh mounts ensure this is persisted information, not LiveView state
    # left behind by the agent stream or a message-based telemetry fixture.
    for _ <- 1..2 do
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button[phx-click='open_message_info'][phx-value-id='#{result.answer.id}']")
      |> render_click()

      assert has_element?(view, "[phx-click='close_message_info']")
      html = render(view)
      assert html =~ "gpt-4.1-mini"
      assert_modal_surface(view, surface, result)
    end
  end

  defp assert_modal_surface(view, :measurements, result) do
    displayed = modal_measurements(render(view))

    for {key, value} <- %{
          "prompt_tokens" => 10,
          "completion_tokens" => 2,
          "total_tokens" => 12,
          "turn_count" => 2,
          "llm_call_count" => 2,
          "tool_call_count" => 1
        } do
      assert displayed[key] == to_string(value), "#{key} must display its persisted value"
    end

    assert {latency, ""} = Integer.parse(displayed["latency_ms"] || "missing")
    assert latency >= 0
    assert latency == result.execution.outcome["measurements"]["latency_ms"]
  end

  defp assert_modal_surface(view, :traces, result) do
    assert has_element?(view, "[data-testid^='trace-row-']")
    view |> element("[data-testid^='trace-row-']", "Tool Call · Add") |> render_click()
    assert has_element?(view, "[data-testid^='trace-details-']")

    trace =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid^='trace-details-'] pre")
      |> LazyHTML.text()
      |> Jason.decode!()

    assert trace["name"] == "add"
    assert trace["arguments"] == %{"value" => 2, "amount" => 3}
    assert trace["status"] == "completed"
    [persisted] = result.execution.tool_results
    assert trace["response"] == persisted["response"]
  end

  defp modal_measurements(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("div.flex")
    |> Enum.flat_map(fn row ->
      [{"div", _, children}] = LazyHTML.to_tree(row)
      spans = Enum.filter(children, &match?({"span", _, _}, &1))

      case spans do
        [key, value] ->
          [{tree_text(key), tree_text(value)}]

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp tree_text(tree),
    do: tree |> List.wrap() |> LazyHTML.from_tree() |> LazyHTML.text() |> String.trim()

  defp assert_modal_authorization(conn, result) do
    staff = user_fixture()
    {:ok, staff} = Accounts.change_password(staff, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: staff.id})
    {:ok, view, html} = live(conn, "/bo/channels/history/#{result.transcript.id}")
    assert html =~ "Not authorized"
    render_hook(view, "open_message_info", %{"id" => result.answer.id})
    refute has_element?(view, "[data-testid^='trace-row-']")
    refute render(view) =~ "gpt-4.1-mini"
    refute render(view) =~ "History answer"
  end

  defp assert_transport(
         strategy,
         reply_to \\ "<strategy-input@example.com>",
         answer \\ "History answer"
       )

  defp assert_transport(:replicated, reply_to, answer) do
    assert_receive {:email, email}, 5_000
    assert Enum.map(email.to, &elem(&1, 1)) == ["alice@example.com", "bob@example.com"]
    assert Enum.map(email.cc, &elem(&1, 1)) == ["carol@example.com"]
    assert email.text_body =~ answer
    assert email.html_body =~ answer
    assert email.headers["In-Reply-To"] == reply_to
    assert email.headers["References"] =~ "<strategy-input@example.com>"
    assert email.headers["Message-ID"] != nil
  end

  defp assert_transport(_strategy, _reply_to, answer) do
    assert_receive {:history_post, payload}, 5_000
    assert payload["channel_id"] in [@shared_room, "alice-dm"]
    # Status posts are allowed; require the complete answer at the real endpoint.
    unless payload["message"] == answer do
      assert_receive {:history_update, %{"message" => ^answer}}, 5_000
    end
  end

  defp assert_recipient_isolation(ctx, result) do
    {:ok, outsider} = People.create_person(%{full_name: "Unauthorized reader"})

    resource =
      {result.transcript.permission_resource_type, result.transcript.permission_resource_id}

    owner = People.get_person!(result.execution.person_id)
    refute Zaq.Permissions.can?(outsider, "read", resource)
    assert Zaq.Permissions.can?(owner, "read", resource)
    assert {:error, :unauthorized} = TranscriptHistory.list(outsider, result.transcript.id, [])
    assert {:ok, projection} = TranscriptHistory.list(owner, result.transcript.id, [])
    assert Enum.map(projection, & &1.message_id) == [result.input.id, result.answer.id]

    for message <- projection do
      refute Map.has_key?(message, :trace)
      refute Map.has_key?(message, :tool_results)
    end

    if ctx.strategy == :replicated do
      assert_replicated_isolation(owner, result)
    else
      assert result.transcript.owner_person_id == nil
    end
  end

  defp assert_replicated_isolation(owner, result) do
    copies = Repo.all(from t in Transcript, where: t.strategy == "replicated")
    assert length(copies) == 3
    assert length(Enum.uniq_by(copies, & &1.owner_person_id)) == 3

    for copy <- copies do
      assert Repo.exists?(
               from p in TranscriptMessage,
                 where: p.transcript_id == ^copy.id and p.message_id == ^result.input.id
             )

      if copy.owner_person_id != result.execution.person_id do
        refute Zaq.Permissions.can?(
                 owner,
                 "read",
                 {copy.permission_resource_type, copy.permission_resource_id}
               )

        assert {:error, :unauthorized} = TranscriptHistory.list(owner, copy.id, [])
      end
    end
  end

  defp ingress(%{strategy: :replicated, config: config}) do
    payload = email_payload("history question", "strategy-input@example.com", "")

    replay = fn ->
      assert :ok = EmailBridge.from_listener(config, payload, mailbox: "INBOX")
    end

    replay.()
    {replay, "<strategy-input@example.com>"}
  end

  defp ingress(%{strategy: :shared_refreshed, config: config, conn: conn}) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, nil, false, %{
               "id" => "root-human",
               "channel_id" => @shared_room,
               "user_id" => "bob",
               "message" => "Authorized project root"
             })

    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, nil, false, %{
               "id" => "alice-presence",
               "channel_id" => @shared_room,
               "message" => "Alice is participating"
             })

    parent =
      Repo.one!(
        from t in Transcript, where: t.external_channel_id == @shared_room and is_nil(t.parent_id)
      )

    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: admin.id})
    {:ok, view, _} = live(conn, "/bo/channels/history/#{parent.id}")
    view |> element("button[phx-click='open_access']") |> render_click()
    view |> element("button[phx-click='refresh']") |> render_click()
    assert render(view) =~ "Provider access refreshed (2 linked People)"

    replay = fn ->
      assert {{:ok, _}, _} =
               MattermostHistoryFixture.post(config, "human", true, %{
                 "channel_id" => @shared_room
               })
    end

    replay.()
    {replay, "incoming-post"}
  end

  defp ingress(%{strategy: strategy, config: config}) do
    replay = fn ->
      result =
        case strategy do
          :shared ->
            MattermostHistoryFixture.post(config, nil, true, %{"channel_id" => @shared_room})

          :direct ->
            MattermostHistoryFixture.direct_post(config, %{"message" => "history question"})
        end

      assert {{:ok, _}, _} = result
    end

    replay.()
    {replay, "incoming-post"}
  end

  defp email_payload(content, id, references) do
    %{
      from: %{address: "alice@example.com", name: "Alice"},
      body_text: content,
      subject: "Strategy acceptance",
      raw_header:
        Enum.join(
          [
            "From: Alice <alice@example.com>",
            "To: ZAQ <bot@example.com>, Bob <bob@example.com>",
            "Cc: Carol <carol@example.com>",
            "Bcc: hidden@example.com",
            "Message-ID: <#{id}>",
            references,
            "Subject: Strategy acceptance",
            "Date: Thu, 8 Oct 2026 12:00:00 +0000"
          ],
          "\r\n"
        )
    }
  end

  defp connector(:replicated, _endpoint) do
    smtp =
      insert_connector("email:smtp", %{
        "from_name" => "ZAQ",
        "from_email" => "bot@example.com"
      })

    insert_connector("email:imap", %{
      "imap" => %{
        "username" => "bot@example.com",
        "selected_mailboxes" => ["INBOX"],
        "smtp_config_id" => smtp.id
      }
    })
  end

  defp connector(_strategy, endpoint) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Real Mattermost strategy",
      provider: "mattermost",
      kind: "retrieval",
      url: String.trim_trailing(endpoint, "/v1"),
      token: "test-token",
      enabled: true,
      settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot"}}
    })
    |> Repo.insert!()
  end

  defp insert_connector(provider, settings) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Strategy #{provider}",
      provider: provider,
      kind: "retrieval",
      url: "localhost",
      token: "test-token",
      enabled: true,
      settings: settings
    })
    |> Repo.insert!()
  end

  defp placements(id),
    do: Repo.all(from p in TranscriptMessage, where: p.transcript_id == ^id, order_by: p.position)

  defp observe_committed_delivery(owner) do
    handler = {__MODULE__, owner}

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ -> observe_query(metadata, handler, owner) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp observe_query(%{query: "commit"}, handler, owner) do
    if Process.delete(handler), do: send(owner, {:strategy_delivery_committed, self()})
    if Process.delete({handler, :queued}), do: send(owner, :strategy_input_queued)
  end

  defp observe_query(%{source: "transcript_messages"} = metadata, handler, _owner) do
    if String.starts_with?(metadata.query, "INSERT") and
         "provider_confirmed" in (metadata[:cast_params] || []),
       do: Process.put(handler, true)
  end

  defp observe_query(%{source: "execution_records"} = metadata, handler, _owner) do
    if String.starts_with?(metadata.query, "UPDATE") and
         "queued" in (metadata[:cast_params] || []),
       do: Process.put({handler, :queued}, true)
  end

  defp observe_query(_metadata, _handler, _owner), do: :ok
end
