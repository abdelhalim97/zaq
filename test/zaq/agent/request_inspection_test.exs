defmodule Zaq.Agent.RequestInspectionTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts.People
  alias Zaq.Agent.{Api, Factory, ServerManager, StreamEvents}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  setup tags do
    if tags[:native] do
      handler = fn _conn, body ->
        request = Jason.decode!(body)
        question = MultiAgentOpenAIStub.latest_user_message(request)

        text =
          if question == "Long native stream", do: long_native_text(), else: question

        response =
          if question == "Long native stream",
            do: long_text_sse(text, request["model"]),
            else: MultiAgentOpenAIStub.text_sse(text, request["model"])

        {200, String.replace(response, "resp_test", "resp_#{Ecto.UUID.generate()}")}
      end

      {child, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child)

      credential =
        ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

      {:ok, person} = People.create_person(%{full_name: "Native inspection owner"})
      actor = %{person: %{id: person.id}}

      {:ok, agent} =
        Zaq.Agent.create_agent(%{
          name: "Native inspection #{System.unique_integer([:positive])}",
          job: "Answer briefly.",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          active: true,
          model_max_context_tokens: 20_000
        })

      scope = "native-inspection:#{Ecto.UUID.generate()}"
      assert {:ok, server} = ServerManager.ensure_server(agent, scope, nil, actor: actor)
      on_exit(fn -> ServerManager.stop_server(agent, scope) end)
      %{agent: agent, actor: actor, scope: scope, server: server, pid: GenServer.whereis(server)}
    else
      :ok
    end
  end

  test "bindings and complete presentation survive streams larger than native trace retention" do
    id = "inspection-#{System.unique_integer([:positive])}"
    actor = %{kind: :bo_user, subject: "1"}
    binding = %{actor: actor, execution_scope: id, runtime_pid: self(), agent: %{id: 1}}
    on_exit(fn -> ServerManager.forget_request(id) end)

    assert :ok = ServerManager.observe_request(id, Map.put(binding, :status, :running))

    for n <- 1..2_100 do
      assert :ok =
               ServerManager.observe_request(id, %{
                 current_content: "segment-#{n}",
                 buffered_chars: n,
                 updated_at_ms: n
               })
    end

    assert :ok = ServerManager.observe_request(id, %{status: :completed})
    assert {:ok, observation} = ServerManager.request_observation(id)
    assert observation.current_content == "segment-2100"
    assert observation.buffered_chars == 2_100
    assert observation.updated_at_ms == 2_100
    assert observation.actor == actor
    assert {:ok, [{^id, ^observation}]} = ServerManager.request_bindings(id, actor)
    assert {:ok, []} = ServerManager.request_bindings(id, %{kind: :bo_user, subject: "2"})

    assert {:error, :ownership_conflict} =
             ServerManager.observe_request(id, %{actor: %{kind: :bo_user, subject: "2"}})
  end

  test "unavailable native state is not acceptance proof" do
    pid = spawn(fn -> :ok end)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert {:error, :stale_runtime} = Factory.request_state(pid, "absent")
  end

  @tag :native
  @tag timeout: 180_000
  test "a real native stream beyond trace capacity retains its complete request-specific presentation",
       ctx do
    {request, result} = consume_native(ctx, "Long native stream")
    text = long_native_text()
    assert result.answer == text
    assert {:ok, %{raw_state: raw}} = Jido.AgentServer.status(ctx.pid)
    native_trace = raw.__strategy__.request_traces[request.id]
    assert native_trace.truncated?
    assert length(native_trace.events) == 2_000
    assert Enum.count(native_trace.events, &(&1.kind == :llm_delta)) < 2_010
    assert {:ok, retained} = ServerManager.request_observation(request.id)
    assert retained.status == :completed
    assert retained.current_content == text
    assert retained.current_stage == :answering
    assert retained.buffered_chars == 0
    assert retained.termination_reason == :final_answer
    assert retained.runtime_pid == ctx.pid
    assert retained.actor == ctx.actor
    assert retained.agent == Map.take(ctx.agent, [:id, :name])
    assert inspect_native(ctx, request.id) == {:ok, retained}
    assert inspect_native(ctx, request.id) == {:ok, retained}
    assert {:ok, ^retained} = ServerManager.request_observation(request.id)
    {later, _} = consume_native(ctx, "Different subsequent answer")
    refute later.id == request.id
    assert inspect_native(ctx, request.id) == {:ok, retained}

    assert {:ok, %{current_content: "Different subsequent answer"}} =
             inspect_native(ctx, later.id)

    stop_native(ctx)
    assert {:error, :stale_runtime} = Factory.request_state(ctx.pid, request.id)
    assert inspect_native(ctx, request.id) == {:ok, retained}
  end

  @tag :native
  @tag timeout: 300_000
  test "native default 100-request eviction and teardown do not evict archived authorized inspection",
       ctx do
    {first, _} = consume_native(ctx, "Oldest answer")
    assert {:ok, retained} = ServerManager.request_observation(first.id)
    assert {:ok, %{raw_state: initial}} = Jido.AgentServer.status(ctx.pid)
    assert (get_in(initial, [:__request_tracking__, :max_requests]) || 100) == 100

    for n <- 1..100 do
      {_request, result} = consume_native(ctx, "New answer #{n}")
      assert result.answer == "New answer #{n}"
    end

    assert {:ok, %{raw_state: raw}} = Jido.AgentServer.status(ctx.pid)
    assert map_size(raw.requests) == 100
    refute Map.has_key?(raw.requests, first.id)
    assert {:error, :not_found} = Factory.request_state(ctx.pid, first.id)
    assert inspect_native(ctx, first.id) == {:ok, retained}

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(
               Event.new(%{request_id: first.id}, :agent,
                 actor: %{kind: :bo_user, subject: "foreign"}
               ),
               :inspect_request,
               nil
             )

    stop_native(ctx)
    assert inspect_native(ctx, first.id) == {:ok, retained}
    assert {:ok, ^retained} = ServerManager.request_observation(first.id)
  end

  defp stop_native(ctx) do
    monitor = Process.monitor(ctx.pid)
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 10_000
  end

  @tag :native
  test "an unavailable runtime cannot restart ServerManager or erase archived inspection during shutdown",
       ctx do
    {request, _} = consume_native(ctx, "Archived before unavailable shutdown")
    assert {:ok, retained} = ServerManager.request_observation(request.id)
    manager = Process.whereis(ServerManager)
    assert :erlang.suspend_process(ctx.pid)

    on_exit(fn ->
      if Process.info(ctx.pid, :status) == {:status, :suspended},
        do: :erlang.resume_process(ctx.pid)
    end)

    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)
    assert Process.whereis(ServerManager) == manager
    assert {:ok, ^retained} = ServerManager.request_observation(request.id)

    if Process.info(ctx.pid, :status) == {:status, :suspended},
      do: :erlang.resume_process(ctx.pid)

    assert inspect_native(ctx, request.id) == {:ok, retained}
  end

  defp consume_native(ctx, question) do
    {request, result} =
      Task.async(fn -> do_consume_native(ctx, question) end) |> Task.await(120_000)

    on_exit(fn -> ServerManager.forget_request(request.id) end)
    {request, result}
  end

  defp do_consume_native(ctx, question) do
    assert {:ok, %{request: request, events: events}} =
             Factory.ask_with_config(ctx.server, question, ctx.agent,
               tool_context: %{actor: ctx.actor}
             )

    incoming = %Incoming{content: question, channel_id: ctx.scope, provider: nil}

    assert {:ok, result} =
             StreamEvents.consume(events, incoming,
               request: request,
               actor: ctx.actor,
               execution_scope: ctx.scope,
               runtime_pid: ctx.pid,
               server_id: ctx.server,
               agent: ctx.agent
             )

    # The stream sink can drain ahead of AgentServer's own event mailbox.
    await_native_idle(ctx.pid, request.id, System.monotonic_time(:millisecond) + 60_000)

    assert {:ok, %{status: :completed, accepting?: false}} =
             Factory.request_state(ctx.pid, request.id)

    {request, result}
  end

  defp await_native_idle(pid, id, deadline) do
    # Awaiting through the native stream is not a barrier for AgentServer's own
    # mailbox. Read its real state until both the request and strategy are idle.
    state =
      try do
        GenServer.call(pid, :get_state, 60_000)
      catch
        :exit, reason ->
          flunk(
            "native state unavailable: #{inspect(reason)}; stack #{inspect(Process.info(pid, :current_stacktrace))}"
          )
      end

    assert {:ok, %{agent: %{state: raw}}} = state

    if raw.requests[id].status == :completed do
      assert {:ok, %{accepting?: false}} = Factory.request_state(pid, id)
    end

    case {raw.requests[id].status, raw.__strategy__.status, raw.__strategy__.active_request_id} do
      {:completed, :completed, _active_id} ->
        :ok

      state ->
        diagnostic = %{
          state: state,
          expected: id,
          requests: map_size(raw.requests),
          last_events:
            raw.__strategy__.request_traces[id].events |> Enum.take(-6) |> Enum.map(& &1.kind)
        }

        assert System.monotonic_time(:millisecond) < deadline,
               "native completion did not settle: #{inspect(diagnostic)}"

        receive do
        after
          10 -> await_native_idle(pid, id, deadline)
        end
    end
  end

  defp inspect_native(ctx, id) do
    Api.handle_event(
      Event.new(%{request_id: id, execution_scope: ctx.scope}, :agent, actor: ctx.actor),
      :inspect_request,
      nil
    ).response
  end

  defp long_text_sse(text, model) do
    deltas =
      Enum.map_join(String.graphemes(text), fn delta ->
        "event: response.output_text.delta\ndata: #{Jason.encode!(%{"delta" => delta})}\n\n"
      end)

    # Reuse the real terminal shape without inserting an additional text delta.
    [_, terminal] =
      String.split(MultiAgentOpenAIStub.text_sse("", model), "event: response.completed",
        parts: 2
      )

    deltas <> "event: response.completed" <> terminal
  end

  defp long_native_text do
    # Distinct deltas detect reordering; repeated identical characters cannot.
    Enum.map_join(1..2_010, fn index -> <<0x4E00 + index::utf8>> end)
  end
end
