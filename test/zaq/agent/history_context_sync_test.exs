defmodule Zaq.Agent.HistoryContextSyncTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import Zaq.SystemConfigFixtures

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Accounts.People
  alias Zaq.Agent.{Api, Factory, HistorySync, RequestControl, ServerManager}
  alias Zaq.Engine.HistoryRuntimeRemovalWorker
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  setup tags do
    owner = self()

    handler = fn _conn, body ->
      request = Jason.decode!(body)

      if tags[:busy] do
        send(owner, {:sync_llm_barrier, self()})

        receive do
          :release_sync_llm -> :ok
        after
          10_000 -> flunk("Sync LLM barrier was not released")
        end
      end

      {200, MultiAgentOpenAIStub.text_sse("Answer", request["model"])}
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, person} = People.create_person(%{full_name: "Context sync owner"})
    actor = %{person: %{id: person.id}}

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Context sync #{System.unique_integer([:positive])}",
        job: "Seed prompt",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        model_max_context_tokens: 20_000,
        enabled_tool_keys: [],
        active: true
      })

    scope = "sync-contract:#{Ecto.UUID.generate()}"
    seed = AIContext.new(system_prompt: "Seed prompt") |> AIContext.append_user("Retained")
    cursors = %{Ecto.UUID.generate() => 1}

    assert {:ok, server} =
             ServerManager.ensure_server(agent, scope, seed,
               actor: actor,
               history_cursors: cursors
             )

    pid = GenServer.whereis(server)
    assert is_pid(pid)
    on_exit(fn -> ServerManager.stop_server(agent, scope) end)

    %{
      agent: agent,
      actor: actor,
      scope: scope,
      seed: seed,
      server: server,
      pid: pid,
      cursors: cursors
    }
  end

  test "idle replacement requires actual applied operation evidence and is idempotent", ctx do
    replacement = AIContext.append_user(ctx.seed, "Incorporated delta")
    op_id = Ecto.UUID.generate()
    assert :ok = Factory.apply_history_context(ctx.pid, replacement, op_id)
    strategy = strategy(ctx.pid)
    assert strategy.context == replacement
    assert op_id in strategy.applied_context_ops
    assert strategy.pending_context_op == nil
    assert :ok = Factory.apply_history_context(ctx.pid, replacement, op_id)
    assert Enum.count(strategy(ctx.pid).applied_context_ops, &(&1 == op_id)) == 1

    assert {:error, :context_apply_unconfirmed} =
             Factory.apply_history_context(
               ctx.pid,
               AIContext.append_user(replacement, "Rebound operation payload"),
               op_id
             )

    assert strategy(ctx.pid).context == replacement
  end

  test "authorized projection belongs only to the exact live lease",
       ctx do
    [transcript_id] = Map.keys(ctx.cursors)
    binding = %{user_message_id: Ecto.UUID.generate(), execution_id: Ecto.UUID.generate()}

    projection = %{
      kind: :canonical,
      transcript_id: transcript_id,
      messages: [],
      cursors: ctx.cursors
    }

    history = %{binding: binding, cursors: ctx.cursors, projection: projection}
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)

    assert :ok =
             ServerManager.bind_history_request(ctx.scope, lease.token, %{
               history: history,
               actor: ctx.actor
             })

    ref = Map.put(history, :lease_ref, {ctx.scope, ctx.pid, lease.token})
    assert {:ok, ^projection} = ServerManager.history_projection(ref, ctx.actor)
    next = %{projection | cursors: %{transcript_id => 2}}
    assert {:ok, ^next} = ServerManager.history_projection(ref, ctx.actor, next)
    assert :sys.get_state(ServerManager).history[ctx.scope].cursors == ctx.cursors

    assert {:error, :stale_history_lease} =
             ServerManager.history_projection(
               %{ref | lease_ref: {ctx.scope, ctx.pid, make_ref()}},
               ctx.actor
             )

    assert {:error, :stale_history_lease} =
             ServerManager.history_projection(
               %{ref | binding: %{binding | execution_id: Ecto.UUID.generate()}},
               ctx.actor
             )

    assert {:error, :unauthorized} =
             ServerManager.history_projection(ref, %{kind: :system, subject: "foreign"})

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)

    assert {:error, :stale_history_lease} = ServerManager.history_projection(ref, ctx.actor)
  end

  test "admission snapshots never publish later captured ends as an incorporated warm cursor",
       ctx do
    [transcript] = Map.keys(ctx.cursors)

    history = %{
      binding: %{user_message_id: Ecto.UUID.generate()},
      cursors: %{transcript => 250},
      scope: ctx.scope,
      projection: %{
        kind: :canonical,
        transcript_id: transcript,
        messages: [],
        cursors: %{transcript => 250}
      }
    }

    HistorySync.with_session(fn session ->
      assert {:ok, opts} =
               HistorySync.admit(
                 [history_session: session, execution_history: history],
                 ctx.scope,
                 ctx.pid,
                 ctx.actor
               )

      assert opts[:execution_history].cursors == ctx.cursors

      assert {:ok, projection} =
               ServerManager.history_projection(opts[:execution_history], ctx.actor)

      assert projection.cursors == ctx.cursors
      assert :sys.get_state(ServerManager).history[ctx.scope].cursors == ctx.cursors
      [%{lease: lease}] = ServerManager.history_requests(session)

      assert :ok =
               ServerManager.complete_history_request(
                 ctx.scope,
                 lease.token,
                 ctx.seed,
                 ctx.cursors
               )
    end)
  end

  test "expired live handoff is removed and cannot acquire a lease after completion", ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)

    waiter =
      Task.async(fn ->
        ServerManager.reserve_history_request(ctx.pid, ctx.actor, Ecto.UUID.generate(), 20)
      end)

    assert {:error, :history_handoff_timeout} = Task.await(waiter, 1_000)
    ledger = :sys.get_state(ServerManager).history[ctx.scope]
    assert ledger.waiters == []
    assert ledger.lease.token == lease.token

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)

    assert :sys.get_state(ServerManager).history[ctx.scope].lease == nil
  end

  test "admission pins are idempotent, scope-bound and released separately from the root lease",
       ctx do
    [transcript_id] = Map.keys(ctx.cursors)
    session = make_ref()
    assert :ok = ServerManager.pin_history_scope(transcript_id, ctx.actor, session)
    assert :ok = ServerManager.pin_history_scope(transcript_id, ctx.actor, session)
    assert map_size(:sys.get_state(ServerManager).history[ctx.scope].pins) == 1

    assert :ok =
             ServerManager.pin_history_scope(
               transcript_id,
               %{kind: :system, subject: "foreign"},
               make_ref()
             )

    assert map_size(:sys.get_state(ServerManager).history[ctx.scope].pins) == 1
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    assert :ok = ServerManager.release_history_pins(session)
    ledger = :sys.get_state(ServerManager).history[ctx.scope]
    assert ledger.pins == %{}
    assert ledger.lease.token == lease.token
    assert Process.alive?(ctx.pid)
  end

  test "retirement is exact-incarnation and waits for accepted pre-submission pins", ctx do
    [transcript_id] = Map.keys(ctx.cursors)
    session = make_ref()
    assert :ok = ServerManager.pin_history_scope(transcript_id, ctx.actor, session)

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: transcript_id,
               person_id: ctx.actor.person.id
             })

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: transcript_id,
               person_id: ctx.actor.person.id
             })

    assert :sys.get_state(ServerManager).history[ctx.scope].retirement != nil
    assert Process.alive?(ctx.pid)
    monitor = Process.monitor(ctx.pid)
    assert :ok = ServerManager.release_history_pins(session)
    assert_receive {:DOWN, ^monitor, :process, pid, _}, 5_000
    assert pid == ctx.pid
    assert :sys.get_state(ServerManager).history[ctx.scope] == nil
  end

  test "idle expiry cannot invalidate accepted work or a replacement incarnation", ctx do
    [transcript_id] = Map.keys(ctx.cursors)
    session = make_ref()
    assert :ok = ServerManager.pin_history_scope(transcript_id, ctx.actor, session)
    manager = Process.whereis(ServerManager)
    send(manager, {:expire_server, ctx.scope, ctx.pid})
    assert :sys.get_state(manager).history[ctx.scope].pid == ctx.pid
    assert Process.alive?(ctx.pid)
    send(manager, {:expire_server, ctx.scope, self()})
    assert :sys.get_state(manager).history[ctx.scope].pid == ctx.pid
    assert Process.alive?(ctx.pid)
  end

  test "new authorized work waits outside Manager for retirement and gets a fresh incarnation",
       ctx do
    [transcript_id] = Map.keys(ctx.cursors)
    session = make_ref()
    assert :ok = ServerManager.pin_history_scope(transcript_id, ctx.actor, session)

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: transcript_id,
               person_id: ctx.actor.person.id
             })

    parent = self()

    waiter =
      Task.async(fn ->
        send(parent, :new_admission_waiting)

        ServerManager.ensure_server(ctx.agent, ctx.scope, ctx.seed,
          actor: ctx.actor,
          history_cursors: ctx.cursors,
          history_session: make_ref()
        )
      end)

    assert_receive :new_admission_waiting, 5_000
    assert :sys.get_state(ServerManager).history[ctx.scope].pid == ctx.pid
    assert :ok = ServerManager.release_history_pins(session)
    assert {:ok, fresh} = Task.await(waiter, 5_000)
    refute GenServer.whereis(fresh) == ctx.pid
    assert Process.alive?(GenServer.whereis(fresh))
  end

  @tag :busy
  test "soft retirement preserves a real blocked model beyond the old force-drain timeout", ctx do
    [transcript_id] = Map.keys(ctx.cursors)
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)

    assert {:ok, %{request: request, events: events}} =
             Factory.ask_with_config(ctx.pid, "Accepted", ctx.agent)

    assert_receive {:sync_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_sync_llm) end)
    monitor = Process.monitor(ctx.pid)

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: transcript_id,
               person_id: ctx.actor.person.id
             })

    refute_receive {:DOWN, ^monitor, :process, _, _}, 1_600
    assert :sys.get_state(ServerManager).history[ctx.scope].lease.token == lease.token
    send(worker, :release_sync_llm)
    assert Enum.any?(Enum.to_list(events), &(&1.kind == :request_completed))
    assert {:ok, %{status: :completed}} = Factory.request_state(ctx.pid, request.id)

    assert {:ok, %{raw_state: %{__strategy__: %{context: context}}}} =
             Jido.AgentServer.status(ctx.pid)

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, context, ctx.cursors)

    assert_receive {:DOWN, ^monitor, :process, pid, _}, 5_000
    assert pid == ctx.pid
  end

  test "a dead pre-submission pin owner releases only its pin", ctx do
    [transcript_id] = Map.keys(ctx.cursors)
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    parent = self()

    owner =
      spawn(fn ->
        :ok = ServerManager.pin_history_scope(transcript_id, ctx.actor, make_ref())
        send(parent, {:pinned, self()})

        receive do
          :release_pin_owner -> :ok
        end
      end)

    assert_receive {:pinned, ^owner}, 5_000
    ledger = :sys.get_state(ServerManager).history[ctx.scope]
    [monitor] = Map.values(ledger.pins)
    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(manager), do: :erlang.trace(manager, false, [:receive]) end)
    send(owner, :release_pin_owner)

    assert_receive {:trace, ^manager, :receive, {:DOWN, ^monitor, :process, ^owner, :normal}},
                   5_000

    ledger = :sys.get_state(ServerManager).history[ctx.scope]
    assert ledger.pins == %{}
    assert ledger.lease.token == lease.token
    assert Process.alive?(ctx.pid)
  end

  test "a dead waiting caller is removed without stopping the current owner", ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(manager), do: :erlang.trace(manager, false, [:receive]) end)

    waiter =
      Task.async(fn ->
        ServerManager.reserve_history_request(ctx.pid, ctx.actor, Ecto.UUID.generate(), 5_000)
      end)

    pid = waiter.pid

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {^pid, _}, {:reserve_history_request, _, _, _, _}}},
                   1_000

    assert length(:sys.get_state(manager).history[ctx.scope].waiters) == 1
    Task.shutdown(waiter, :brutal_kill)
    assert_receive {:trace, ^manager, :receive, {:DOWN, _, :process, ^pid, _}}, 1_000
    ledger = :sys.get_state(manager).history[ctx.scope]
    assert ledger.waiters == []
    assert ledger.lease.token == lease.token
    assert Process.alive?(ctx.pid)
  end

  test "retirement selects a stable Person and inherited history sources, not names", ctx do
    [root] = Map.keys(ctx.cursors)
    {:ok, person} = People.create_person(%{full_name: "Unaffected history owner"})
    other_actor = %{person: %{id: person.id}}
    thread = "thread-incarnation:#{Ecto.UUID.generate()}"
    other = "same-source-other-person:#{Ecto.UUID.generate()}"
    unrelated = "other-source-same-person:#{Ecto.UUID.generate()}"

    for {scope, actor, cursors} <- [
          {thread, ctx.actor, Map.put(ctx.cursors, Ecto.UUID.generate(), 3)},
          {other, other_actor, ctx.cursors},
          {unrelated, ctx.actor, %{Ecto.UUID.generate() => 4}}
        ] do
      assert {:ok, _} =
               ServerManager.ensure_server(ctx.agent, scope, ctx.seed,
                 actor: actor,
                 history_cursors: cursors
               )

      on_exit(fn -> ServerManager.stop_server(ctx.agent, scope) end)
    end

    state = :sys.get_state(ServerManager)
    thread_pid = state.history[thread].pid
    root_monitor = Process.monitor(ctx.pid)
    thread_monitor = Process.monitor(thread_pid)

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: root,
               person_id: ctx.actor.person.id
             })

    assert_receive {:DOWN, ^root_monitor, :process, _, _}, 5_000
    assert_receive {:DOWN, ^thread_monitor, :process, _, _}, 5_000
    state = :sys.get_state(ServerManager)
    assert state.history[ctx.scope] == nil
    assert state.history[thread] == nil
    assert Process.alive?(state.history[other].pid)
    assert Process.alive?(state.history[unrelated].pid)
    # A stale exact-incarnation callback cannot stop a freshly authorized replacement.
    assert {:ok, replacement} =
             ServerManager.ensure_server(ctx.agent, ctx.scope, ctx.seed,
               actor: ctx.actor,
               history_cursors: ctx.cursors
             )

    send(ServerManager, {:history_idle_result, ctx.scope, ctx.pid, make_ref(), :ok})
    :sys.get_state(ServerManager)
    assert Process.alive?(GenServer.whereis(replacement))

    assert Process.alive?(state.history[other].pid)
  end

  test "retirement cannot select unrelated principals or sources",
       ctx do
    [root] = Map.keys(ctx.cursors)

    for {source, person} <- [{root, 0}, {Ecto.UUID.generate(), ctx.actor.person.id}] do
      assert :ok = ServerManager.retire_history_scope(%{transcript_id: source, person_id: person})
    end

    assert Process.alive?(ctx.pid)
  end

  test "obsolete persisted jobs are inert during transactions and cannot stop a replacement",
       ctx do
    [root] = Map.keys(ctx.cursors)

    job = %Oban.Job{
      args: %{
        "transcript_id" => root,
        "person_ids" => [ctx.actor.person.id],
        "event_id" => Ecto.UUID.generate(),
        "generation" => 1
      }
    }

    assert {:error, :rollback_removal} =
             Repo.transaction(fn ->
               assert :ok = HistoryRuntimeRemovalWorker.perform(job)

               assert Process.alive?(ctx.pid)
               Repo.rollback(:rollback_removal)
             end)

    assert Process.alive?(ctx.pid)

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "Zaq.Engine.HistoryRuntimeRemovalWorker"),
             :count
           ) == 0

    assert :ok = HistoryRuntimeRemovalWorker.perform(job)
    assert Process.alive?(ctx.pid)
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)
    refute Process.alive?(ctx.pid)

    assert {:ok, replacement} =
             ServerManager.ensure_server(ctx.agent, ctx.scope, ctx.seed,
               actor: ctx.actor,
               history_cursors: ctx.cursors
             )

    assert :ok = HistoryRuntimeRemovalWorker.perform(job)
    assert Process.alive?(GenServer.whereis(replacement))
  end

  test "retirement advances an accepted live reservation instead of cancelling it",
       ctx do
    [root] = Map.keys(ctx.cursors)
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(manager, false, [:receive]) end)

    parent = self()

    waiter =
      Task.async(fn ->
        {:ok, reservation} =
          ServerManager.reserve_history_request(ctx.pid, ctx.actor, Ecto.UUID.generate(), 5_000)

        send(parent, {:retired_reservation_admitted, reservation})

        ServerManager.complete_history_request(
          ctx.scope,
          reservation.lease.token,
          ctx.seed,
          ctx.cursors
        )
      end)

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {waiter_pid, _}, {:reserve_history_request, _, _, _, _}}},
                   5_000

    assert waiter_pid == waiter.pid
    assert length(:sys.get_state(manager).history[ctx.scope].waiters) == 1

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: root,
               person_id: ctx.actor.person.id
             })

    monitor = Process.monitor(ctx.pid)
    assert Process.alive?(ctx.pid)

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)

    assert_receive {:retired_reservation_admitted, reservation}, 5_000
    assert reservation.lease.pid == ctx.pid
    assert :ok = Task.await(waiter, 5_000)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
  end

  @tag :busy
  test "retirement retains successful native inspection after the consumer finishes", ctx do
    [root] = Map.keys(ctx.cursors)
    session = make_ref()
    assert :ok = ServerManager.pin_history_scope(root, ctx.actor, session)

    assert {:ok, %{request: request}} =
             Factory.ask_with_config(ctx.server, "Question", ctx.agent,
               tool_context: %{actor: ctx.actor}
             )

    assert_receive {:sync_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_sync_llm) end)

    assert :ok =
             ServerManager.observe_request(request.id, %{
               status: :running,
               actor: ctx.actor,
               execution_scope: ctx.scope,
               runtime_pid: ctx.pid,
               server_id: ctx.server
             })

    monitor = Process.monitor(ctx.pid)

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: root,
               person_id: ctx.actor.person.id
             })

    assert Process.alive?(ctx.pid)
    send(worker, :release_sync_llm)
    assert {:ok, "Answer"} = Factory.await(request, timeout: 5_000)
    assert :ok = ServerManager.observe_request(request.id, %{status: :completed})
    assert :ok = ServerManager.release_history_pins(session)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert {:ok, registry} = ServerManager.request_observation(request.id)
    assert registry.status == :completed
    refute Map.has_key?(registry, :history_removed)

    assert {:error, :terminal_request} =
             ServerManager.observe_request(request.id, %{status: :streaming})

    assert {:error, :not_found} =
             RequestControl.find_native_request(ctx.scope, ctx.actor, ctx.pid)
  end

  test "API completion sessions are process-owned, immutable, and disposed after exceptions",
       ctx do
    monitor = Process.monitor(ctx.pid)

    assert_raise RuntimeError, "unhandled outcome", fn ->
      HistorySync.with_session(fn session ->
        assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
        details = %{session: session}
        assert :ok = ServerManager.bind_history_request(ctx.scope, lease.token, details)
        assert :ok = ServerManager.bind_history_request(ctx.scope, lease.token, details)

        assert {:error, :history_binding_conflict} =
                 ServerManager.bind_history_request(
                   ctx.scope,
                   lease.token,
                   %{session: make_ref()}
                 )

        assert [%{server_id: scope}] = ServerManager.history_requests(session)
        assert scope == ctx.scope
        assert [] = Task.async(fn -> ServerManager.history_requests(session) end) |> Task.await()
        raise "unhandled outcome"
      end)
    end

    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert :sys.get_state(ServerManager).history[ctx.scope] == nil
  end

  test "low-level steer and inject keep the native idle refusal without automatic recovery",
       ctx do
    assert {:ok, %{request: request}} =
             Factory.ask_with_config(ctx.server, "Question", ctx.agent,
               tool_context: %{actor: ctx.actor}
             )

    assert {:ok, "Answer"} = Factory.await(request, timeout: 5_000)

    assert :ok =
             ServerManager.observe_request(request.id, %{
               actor: ctx.actor,
               execution_scope: ctx.scope,
               status: :completed,
               runtime_pid: ctx.pid,
               server_id: ctx.server
             })

    for action <- [:steer_request, :inject_request] do
      event =
        Zaq.Event.new(%{request_id: request.id, content: "Late correction"}, :agent,
          actor: ctx.actor,
          opts: [live_followup: true]
        )

      assert %{response: {:error, {:rejected, :idle}}} = Api.handle_event(event, action, nil)
    end

    assert Process.alive?(ctx.pid)
    assert strategy(ctx.pid).status == :completed
  end

  test "a failed persisted outcome disposes the runtime without advancing its cursor", ctx do
    monitor = Process.monitor(ctx.pid)

    HistorySync.with_session(fn session ->
      assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
      assert :ok = ServerManager.bind_history_request(ctx.scope, lease.token, %{session: session})
      assert :ok = HistorySync.complete(session, %{}, %{metadata: %{error: true}})
      assert ServerManager.history_requests(session) == []
    end)

    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert :sys.get_state(ServerManager).history[ctx.scope] == nil
  end

  test "stale idle and retirement callbacks cannot stop a regranted replacement",
       ctx do
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)

    assert {:ok, replacement} =
             ServerManager.ensure_server(ctx.agent, ctx.scope, ctx.seed,
               actor: ctx.actor,
               history_cursors: ctx.cursors
             )

    pid = GenServer.whereis(replacement)
    send(ServerManager, {:expire_server, ctx.scope, ctx.pid})
    send(ServerManager, {:history_idle_result, ctx.scope, ctx.pid, make_ref(), :ok})
    send(ServerManager, {:check_history_retirements, ctx.scope, ctx.pid})
    assert :sys.get_state(ServerManager).history[ctx.scope].pid == pid
    assert Process.alive?(pid)
  end

  test "context operations require an exact PID and nonempty operation identity", ctx do
    for {runtime, op_id} <- [{ctx.server, Ecto.UUID.generate()}, {ctx.pid, ""}, {ctx.pid, nil}] do
      assert {:error, :invalid_context_operation} =
               Factory.apply_history_context(runtime, ctx.seed, op_id)
    end

    assert strategy(ctx.pid).applied_context_ops == []
  end

  test "an old PID cannot apply its snapshot to a replacement scope incarnation", ctx do
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)

    assert {:ok, replacement} =
             ServerManager.ensure_server(ctx.agent, ctx.scope, ctx.seed, actor: ctx.actor)

    replacement_pid = GenServer.whereis(replacement)
    assert replacement_pid != ctx.pid
    before = strategy(replacement_pid)

    assert {:error, :runtime_unavailable} =
             Factory.apply_history_context(
               ctx.pid,
               AIContext.append_user(ctx.seed, "Stale delta"),
               Ecto.UUID.generate()
             )

    assert strategy(replacement_pid) == before
  end

  @tag :busy
  test "active execution refuses replacement rather than queueing a stale context operation",
       ctx do
    assert {:ok, request} =
             Factory.ask_with_config(ctx.server, "Question", ctx.agent,
               tool_context: %{actor: ctx.actor}
             )

    assert_receive {:sync_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_sync_llm) end)
    before = strategy(ctx.pid)

    assert {:error, :runtime_busy} =
             Factory.apply_history_context(
               ctx.pid,
               AIContext.append_user(ctx.seed, "Unsafe queued replacement"),
               Ecto.UUID.generate()
             )

    assert strategy(ctx.pid).pending_context_op == nil
    assert strategy(ctx.pid).applied_context_ops == before.applied_context_ops
    send(worker, :release_sync_llm)
    assert {:ok, "Answer"} = Factory.await(request, timeout: 5_000)
    assert strategy(ctx.pid).pending_context_op == nil
    refute inspect(strategy(ctx.pid).context) =~ "Unsafe queued replacement"
  end

  defp strategy(pid) do
    assert {:ok, %{raw_state: %{__strategy__: strategy}}} = Jido.AgentServer.status(pid)
    strategy
  end

  test "a queued next request receives the cursor only after confirmed context application",
       ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    assert lease.cursors == ctx.cursors
    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, self()}])
    on_exit(fn -> :erlang.trace(manager, false, [:receive]) end)
    owner = self()

    waiter =
      Task.async(fn ->
        result = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
        send(owner, {:next_history_lease, result})

        receive do
          :release_context_waiter -> result
        end
      end)

    on_exit(fn -> send(waiter.pid, :release_context_waiter) end)

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {waiter_pid, _}, {:begin_history_request, _, _, _}}},
                   5_000

    assert waiter_pid == waiter.pid
    assert length(:sys.get_state(manager).history[ctx.scope].waiters) == 1
    assert Task.yield(waiter, 0) == nil
    replacement = AIContext.append_user(ctx.seed, "Committed association")
    cursors = Map.new(ctx.cursors, fn {id, cursor} -> {id, cursor + 1} end)

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, replacement, cursors)

    assert_receive {:next_history_lease, {:ok, next}}, 5_000
    assert next.token != lease.token
    assert next.cursors == cursors
    assert strategy(ctx.pid).context == replacement
    assert lease.op_id in strategy(ctx.pid).applied_context_ops
    send(waiter.pid, :release_context_waiter)
    assert {:ok, ^next} = Task.await(waiter, 5_000)
  end

  test "lease ownership and cursor identity cannot be rebound", ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)

    assert {:error, :history_request_active} =
             ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)

    assert {:error, :lease_owner_mismatch} =
             Task.async(fn ->
               ServerManager.complete_history_request(
                 ctx.scope,
                 lease.token,
                 ctx.seed,
                 ctx.cursors
               )
             end)
             |> Task.await(5_000)

    for cursors <- [
          %{},
          %{Ecto.UUID.generate() => 2},
          Map.new(ctx.cursors, fn {id, _} -> {id, 0} end)
        ] do
      assert {:error, :invalid_history_cursor} =
               ServerManager.complete_history_request(
                 ctx.scope,
                 lease.token,
                 ctx.seed,
                 cursors
               )
    end

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)

    assert {:error, :stale_history_lease} =
             ServerManager.complete_history_request(
               ctx.scope,
               lease.token,
               AIContext.append_user(ctx.seed, "Stale"),
               ctx.cursors
             )

    refute inspect(strategy(ctx.pid).context) =~ "Stale"
  end

  test "actor mismatch cannot acquire a history lease", ctx do
    assert {:error, :execution_actor_mismatch} =
             ServerManager.begin_history_request(ctx.scope, ctx.pid, nil)

    {:ok, other} = People.create_person(%{full_name: "Different context owner"})

    assert {:error, :execution_actor_mismatch} =
             ServerManager.begin_history_request(ctx.scope, ctx.pid, %{person: %{id: other.id}})

    assert :sys.get_state(ServerManager).history[ctx.scope].lease == nil
  end

  test "a live reservation is adopted only by its process, session and canonical input", ctx do
    session = make_ref()
    input = Ecto.UUID.generate()

    assert {:ok, reservation} =
             ServerManager.reserve_history_request(ctx.pid, ctx.actor, input, 1_000)

    lease = reservation.lease

    assert :ok =
             ServerManager.bind_history_request(ctx.scope, lease.token, %{
               session: session,
               actor: ctx.actor,
               input_id: input
             })

    details = %{
      session: session,
      actor: ctx.actor,
      history: %{binding: %{user_message_id: input}}
    }

    assert {:error, :lease_owner_mismatch} =
             Task.async(fn ->
               ServerManager.adopt_history_request(ctx.scope, ctx.pid, lease.token, details)
             end)
             |> Task.await()

    assert {:error, :history_binding_conflict} =
             ServerManager.adopt_history_request(ctx.scope, ctx.pid, lease.token, %{
               details
               | session: make_ref()
             })

    assert {:error, :history_binding_conflict} =
             ServerManager.adopt_history_request(ctx.scope, ctx.pid, lease.token, %{
               details
               | history: %{binding: %{user_message_id: Ecto.UUID.generate()}}
             })

    assert :ok = ServerManager.adopt_history_request(ctx.scope, ctx.pid, lease.token, details)

    assert [%{lease: %{token: token, details: ^details}}] =
             ServerManager.history_requests(session)

    assert token == lease.token

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)
  end

  test "a session cannot reserve again after its live reservation is bound", ctx do
    input = Ecto.UUID.generate()

    HistorySync.with_session(fn session ->
      assert {:ok, reservation} =
               HistorySync.reserve_followup(
                 session,
                 %{runtime_pid: ctx.pid},
                 ctx.actor,
                 input,
                 1_000
               )

      assert {:error, :history_binding_conflict} =
               HistorySync.reserve_followup(
                 session,
                 %{runtime_pid: ctx.pid},
                 ctx.actor,
                 input,
                 1_000
               )

      assert :ok = ServerManager.abort_history_request(ctx.scope, reservation.lease.token)
      assert ServerManager.history_requests(session) == []
      assert :sys.get_state(ServerManager).history[ctx.scope] == nil
    end)
  end

  test "admitting a matching reservation reuses its exact lease without another reservation",
       ctx do
    [transcript] = Map.keys(ctx.cursors)
    input = Ecto.UUID.generate()

    projection = %{
      kind: :canonical,
      transcript_id: transcript,
      messages: [],
      cursors: ctx.cursors
    }

    history = %{
      binding: %{user_message_id: input, execution_id: Ecto.UUID.generate()},
      cursors: ctx.cursors,
      scope: ctx.scope,
      projection: projection
    }

    HistorySync.with_session(fn session ->
      assert {:ok, reservation} =
               ServerManager.reserve_history_request(ctx.pid, ctx.actor, input, 1_000)

      lease = reservation.lease

      assert :ok =
               ServerManager.bind_history_request(ctx.scope, lease.token, %{
                 session: session,
                 actor: ctx.actor,
                 input_id: input
               })

      assert {:ok, opts} =
               HistorySync.admit(
                 [
                   history_session: session,
                   execution_history: history,
                   history_reservation: reservation
                 ],
                 ctx.scope,
                 ctx.pid,
                 ctx.actor
               )

      assert [%{lease: adopted}] = ServerManager.history_requests(session)
      assert adopted.token == lease.token
      assert adopted.op_id == lease.op_id
      assert adopted.pid == lease.pid
      assert adopted.cursors == lease.cursors
      assert opts[:execution_history].cursors == lease.cursors

      assert :ok = HistorySync.complete(session, %{}, %{body: "", metadata: %{error: true}})
      assert ServerManager.history_requests(session) == []
      assert :sys.get_state(ServerManager).history[ctx.scope] == nil
    end)
  end

  test "a reservation for another server incarnation is rejected without changing the runtime",
       ctx do
    input = Ecto.UUID.generate()

    assert {:ok, reservation} =
             ServerManager.reserve_history_request(ctx.pid, ctx.actor, input, 1_000)

    history = %{binding: %{user_message_id: input}, cursors: ctx.cursors, scope: ctx.scope}

    HistorySync.with_session(fn session ->
      assert {:error, :stale_history_lease} =
               HistorySync.admit(
                 [
                   history_session: session,
                   execution_history: history,
                   history_reservation: %{
                     server_id: ctx.scope,
                     lease: %{pid: ctx.pid, token: reservation.lease.token}
                   }
                 ],
                 ctx.scope,
                 self(),
                 ctx.actor
               )

      assert :sys.get_state(ServerManager).history[ctx.scope].lease.token ==
               reservation.lease.token

      assert strategy(ctx.pid).context == ctx.seed
      assert :ok = ServerManager.abort_history_request(ctx.scope, reservation.lease.token)
    end)
  end

  test "successful outgoing completion without an assistant id aborts the owned lease", ctx do
    HistorySync.with_session(fn session ->
      assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
      assert :ok = ServerManager.bind_history_request(ctx.scope, lease.token, %{session: session})
      assert :ok = HistorySync.complete(session, %{}, %{body: "", metadata: %{}})
      assert ServerManager.history_requests(session) == []
    end)

    assert :sys.get_state(ServerManager).history[ctx.scope] == nil
    refute Process.alive?(ctx.pid)
  end

  test "completion with an error outcome disposes the owned runtime", ctx do
    HistorySync.with_session(fn session ->
      assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
      assert :ok = ServerManager.bind_history_request(ctx.scope, lease.token, %{session: session})

      assert :ok =
               HistorySync.complete(session, %{}, %{
                 body: "",
                 metadata: %{error: true}
               })

      assert ServerManager.history_requests(session) == []
    end)

    assert :sys.get_state(ServerManager).history[ctx.scope] == nil
    refute Process.alive?(ctx.pid)
  end

  test "malformed projection is rejected while the valid lease remains usable", ctx do
    [transcript] = Map.keys(ctx.cursors)
    binding = %{user_message_id: Ecto.UUID.generate()}

    projection = %{
      kind: :canonical,
      transcript_id: transcript,
      messages: [],
      cursors: ctx.cursors
    }

    history = %{binding: binding, cursors: ctx.cursors, projection: projection}
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)

    assert :ok =
             ServerManager.bind_history_request(ctx.scope, lease.token, %{
               history: history,
               actor: ctx.actor
             })

    ref = Map.put(history, :lease_ref, {ctx.scope, ctx.pid, lease.token})

    assert {:error, :invalid_history_projection} =
             ServerManager.history_projection(ref, ctx.actor, %{})

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)
  end

  test "wrong lease tokens cannot bind or abort the exact valid lease", ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    details = %{session: make_ref()}

    assert {:error, :stale_history_lease} =
             ServerManager.bind_history_request(ctx.scope, make_ref(), details)

    assert {:error, :stale_history_lease} =
             ServerManager.abort_history_request(ctx.scope, make_ref())

    assert :ok = ServerManager.bind_history_request(ctx.scope, lease.token, details)

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)
  end

  test "adopting an unbound reservation with history details conflicts without losing its lease",
       ctx do
    input = Ecto.UUID.generate()

    assert {:ok, reservation} =
             ServerManager.reserve_history_request(ctx.pid, ctx.actor, input, 1_000)

    details = %{
      session: make_ref(),
      actor: ctx.actor,
      history: %{binding: %{user_message_id: input}}
    }

    assert {:error, :history_binding_conflict} =
             ServerManager.adopt_history_request(
               ctx.scope,
               ctx.pid,
               reservation.lease.token,
               details
             )

    assert :sys.get_state(ServerManager).history[ctx.scope].lease.token == reservation.lease.token
    assert :ok = ServerManager.abort_history_request(ctx.scope, reservation.lease.token)
  end

  test "invalid pins reject invalid principals and session references", ctx do
    [transcript] = Map.keys(ctx.cursors)

    assert {:error, :invalid_history_pin} =
             ServerManager.pin_history_scope(transcript, nil, make_ref())

    assert {:error, :invalid_history_pin} =
             ServerManager.pin_history_scope(transcript, ctx.actor, :not_a_reference)
  end

  test "only the owner of a retirement pin may target its retiring runtime", ctx do
    [transcript] = Map.keys(ctx.cursors)
    session = make_ref()
    assert :ok = ServerManager.pin_history_scope(transcript, ctx.actor, session)

    assert :ok =
             ServerManager.retire_history_scope(%{
               transcript_id: transcript,
               person_id: ctx.actor.person.id
             })

    assert :ok = ServerManager.admitted_history_target(ctx.pid, session)
    assert {:error, :server_retiring} = ServerManager.admitted_history_target(ctx.pid, make_ref())
    assert Process.alive?(ctx.pid)
    assert :ok = ServerManager.release_history_pins(session)
  end

  test "a correction reservation remains FIFO behind already-waiting ordinary admission", ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    manager = Process.whereis(ServerManager)
    :erlang.trace(manager, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(manager), do: :erlang.trace(manager, false, [:receive]) end)
    parent = self()
    cursors = Map.new(ctx.cursors, fn {id, value} -> {id, value + 1} end)

    ordinary =
      Task.async(fn ->
        {:ok, next} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
        send(parent, {:ordinary_admitted, next})

        receive do
          :complete_ordinary ->
            ServerManager.complete_history_request(ctx.scope, next.token, ctx.seed, cursors)
        end
      end)

    on_exit(fn -> send(ordinary.pid, :complete_ordinary) end)
    pid = ordinary.pid

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {^pid, _}, {:begin_history_request, _, _, _}}},
                   1_000

    correction =
      Task.async(fn ->
        {:ok, reserved} =
          ServerManager.reserve_history_request(ctx.pid, ctx.actor, Ecto.UUID.generate(), 5_000)

        send(parent, {:correction_admitted, reserved})
        ServerManager.complete_history_request(ctx.scope, reserved.lease.token, ctx.seed, cursors)
      end)

    pid = correction.pid

    assert_receive {:trace, ^manager, :receive,
                    {:"$gen_call", {^pid, _}, {:reserve_history_request, _, _, _, _}}},
                   1_000

    assert length(:sys.get_state(manager).history[ctx.scope].waiters) == 2

    assert :ok =
             ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, ctx.cursors)

    assert_receive {:ordinary_admitted, _}, 1_000
    refute_received {:correction_admitted, _}
    send(ordinary.pid, :complete_ordinary)
    assert_receive {:correction_admitted, reserved}, 1_000
    assert reserved.lease.cursors == cursors
    assert :ok = Task.await(ordinary)
    assert :ok = Task.await(correction)
    assert :sys.get_state(manager).history[ctx.scope].lease == nil
  end

  for failure <- [:aborted, :replacement] do
    @tag handoff_failure: failure
    test "waiting reservation is fenced on #{failure} without migration to another runtime",
         ctx do
      assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
      input = Ecto.UUID.generate()
      manager = Process.whereis(ServerManager)
      :erlang.trace(manager, true, [:receive, {:tracer, self()}])
      on_exit(fn -> if Process.alive?(manager), do: :erlang.trace(manager, false, [:receive]) end)

      waiter =
        Task.async(fn ->
          ServerManager.reserve_history_request(ctx.pid, ctx.actor, input, 5_000)
        end)

      pid = waiter.pid

      assert_receive {:trace, ^manager, :receive,
                      {:"$gen_call", {^pid, _}, {:reserve_history_request, _, _, _, _}}},
                     1_000

      assert length(:sys.get_state(manager).history[ctx.scope].waiters) == 1

      case ctx.handoff_failure do
        :aborted ->
          assert :ok = ServerManager.abort_history_request(ctx.scope, lease.token)

        :replacement ->
          assert :ok = ServerManager.stop_server_if_current(ctx.agent, ctx.scope, ctx.pid)
      end

      assert {:error, reason} = Task.await(waiter, 1_000)
      assert reason == :stale_runtime
      assert :sys.get_state(manager).history[ctx.scope] == nil

      assert {:error, :stale_runtime} =
               ServerManager.reserve_history_request(ctx.pid, ctx.actor, input, 10)
    end
  end

  test "an abandoned owner invalidates its runtime without publishing a staged cursor", ctx do
    owner = self()

    holder =
      Task.async(fn ->
        assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
        send(owner, {:abandoned_history_lease, lease})

        receive do
          :abandon_history_lease -> :ok
        end
      end)

    on_exit(fn -> send(holder.pid, :abandon_history_lease) end)
    assert_receive {:abandoned_history_lease, _lease}, 5_000
    monitor = Process.monitor(ctx.pid)
    send(holder.pid, :abandon_history_lease)
    assert :ok = Task.await(holder, 5_000)
    assert_receive {:DOWN, ^monitor, :process, pid, _}, 5_000
    assert pid == ctx.pid
    assert :sys.get_state(ServerManager).history[ctx.scope] == nil
  end

  @tag :busy
  test "failed context application invalidates rather than advancing an incorporated cursor",
       ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)

    assert {:ok, request} =
             Factory.ask_with_config(ctx.server, "Question", ctx.agent,
               tool_context: %{actor: ctx.actor}
             )

    assert_receive {:sync_llm_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_sync_llm) end)
    monitor = Process.monitor(ctx.pid)
    next = Map.new(ctx.cursors, fn {id, position} -> {id, position + 1} end)

    assert {:error, :runtime_busy} =
             ServerManager.complete_history_request(
               ctx.scope,
               lease.token,
               AIContext.append_user(ctx.seed, "Not incorporated"),
               next
             )

    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert :sys.get_state(ServerManager).history[ctx.scope] == nil
    send(worker, :release_sync_llm)
    assert {:error, _} = Factory.await(request, timeout: 5_000)
  end

  test "stale completion cannot replace a new incarnation's context or cursor", ctx do
    assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)
    new_cursors = Map.new(ctx.cursors, fn {id, position} -> {id, position + 5} end)

    assert {:ok, server} =
             ServerManager.ensure_server(ctx.agent, ctx.scope, ctx.seed,
               actor: ctx.actor,
               history_cursors: new_cursors
             )

    assert {:error, :stale_history_lease} =
             ServerManager.complete_history_request(
               ctx.scope,
               lease.token,
               AIContext.append_user(ctx.seed, "Old incarnation"),
               new_cursors
             )

    assert {:ok, new_lease} =
             ServerManager.begin_history_request(ctx.scope, GenServer.whereis(server), ctx.actor)

    assert new_lease.cursors == new_cursors
    assert strategy(GenServer.whereis(server)).context == ctx.seed
  end

  property "confirmed cursor commits are monotonic and old lease tokens never reopen", ctx do
    check all(increment <- integer(0..10), max_runs: 8) do
      assert {:ok, lease} = ServerManager.begin_history_request(ctx.scope, ctx.pid, ctx.actor)
      next = Map.new(lease.cursors, fn {id, position} -> {id, position + increment} end)
      assert :ok = ServerManager.complete_history_request(ctx.scope, lease.token, ctx.seed, next)
      assert :sys.get_state(ServerManager).history[ctx.scope].cursors == next

      assert {:error, :stale_history_lease} =
               ServerManager.complete_history_request(
                 ctx.scope,
                 lease.token,
                 ctx.seed,
                 lease.cursors
               )

      assert :sys.get_state(ServerManager).history[ctx.scope].cursors == next
    end
  end
end
