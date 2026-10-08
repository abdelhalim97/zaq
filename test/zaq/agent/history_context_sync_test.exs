defmodule Zaq.Agent.HistoryContextSyncTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import Zaq.SystemConfigFixtures

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Accounts.People
  alias Zaq.Agent.{Factory, HistorySync, ServerManager}
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
