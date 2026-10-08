defmodule Zaq.Agent.HistoryContextSyncTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Accounts.People
  alias Zaq.Agent.{Factory, ServerManager}
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
    assert {:ok, server} = ServerManager.ensure_server(agent, scope, seed, actor: actor)
    pid = GenServer.whereis(server)
    assert is_pid(pid)
    on_exit(fn -> ServerManager.stop_server(agent, scope) end)
    %{agent: agent, actor: actor, scope: scope, seed: seed, server: server, pid: pid}
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
end
