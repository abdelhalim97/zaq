defmodule Zaq.Agent.RequestRegistryTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Zaq.Agent.RequestRegistry

  test "active lookup matches literal principal and exact scope without terminal requests" do
    scope = "lookup-#{System.unique_integer([:positive])}"
    actor = %{person: %{id: 123}}
    id = "active-#{System.unique_integer([:positive])}"

    assert :ok =
             RequestRegistry.put(id, %{
               actor: actor,
               execution_scope: scope,
               status: :streaming,
               runtime_pid: self()
             })

    assert {:ok, {^id, _}} = RequestRegistry.find_active(scope, actor)
    assert {:error, :not_found} = RequestRegistry.find_active(scope, %{person: %{id: 124}})
    assert {:error, :not_found} = RequestRegistry.find_active(scope <> "-other", actor)
    assert :ok = RequestRegistry.put(id, %{status: :completed})
    assert {:error, :not_found} = RequestRegistry.find_active(scope, actor)
    assert :ok = RequestRegistry.delete(id)
  end

  @table :zaq_agent_request_registry

  test "same Person/scope requests are selected only for the exact configured agent and incarnation" do
    scope = "agent-scope-#{System.unique_integer([:positive])}"
    actor = %{person: %{id: 123}}
    first = "agent-one-#{System.unique_integer([:positive])}"
    second = "agent-two-#{System.unique_integer([:positive])}"

    runtime =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> send(runtime, :finish) end)

    assert :ok =
             RequestRegistry.put(first, %{
               actor: actor,
               execution_scope: scope,
               status: :streaming,
               runtime_pid: self(),
               agent: %{id: 1, name: "One"}
             })

    assert :ok =
             RequestRegistry.put(second, %{
               actor: actor,
               execution_scope: scope,
               status: :streaming,
               runtime_pid: runtime,
               agent: %{id: 2, name: "Two"}
             })

    assert {:error, :ambiguous_request} = RequestRegistry.find_active(scope, actor)
    assert {:ok, {^first, _}} = RequestRegistry.find_active(scope, actor, self())
    assert {:ok, {^second, _}} = RequestRegistry.find_active(scope, actor, %{agent_id: "2"})

    assert {:error, :ownership_conflict} =
             RequestRegistry.put(first, %{agent: %{id: 2, name: "Two"}})

    assert :ok = RequestRegistry.delete(first)
    assert :ok = RequestRegistry.delete(second)
  end

  setup do
    ensure_registry_available!()

    on_exit(fn ->
      restore_registry!()
    end)

    :ok
  end

  test "get returns not_found for non-binary request ids" do
    assert {:error, :not_found} = RequestRegistry.get(nil)
    assert {:error, :not_found} = RequestRegistry.get(:request_id)
    assert {:error, :not_found} = RequestRegistry.get(123)
  end

  test "delete removes an existing request" do
    request_id = "req-reg-#{System.unique_integer([:positive])}"

    assert :ok = RequestRegistry.put(request_id, %{status: :streaming})
    assert {:ok, %{status: :streaming}} = RequestRegistry.get(request_id)
    assert :ok = RequestRegistry.delete(request_id)
    assert {:error, :not_found} = RequestRegistry.get(request_id)
  end

  test "delete ignores non-binary request ids" do
    assert :ok = RequestRegistry.delete(nil)
    assert :ok = RequestRegistry.delete(:request_id)
    assert :ok = RequestRegistry.delete(123)
  end

  test "terminal request state cannot be reopened by a trailing stream flush" do
    id = "terminal-#{System.unique_integer([:positive])}"
    assert :ok = RequestRegistry.put(id, %{status: :running, runtime_pid: self()})
    assert :ok = RequestRegistry.put(id, %{status: :completed, runtime_pid: self()})

    assert {:error, :terminal_request} =
             RequestRegistry.put(id, %{status: :streaming, runtime_pid: self()})

    assert {:ok, %{status: :completed}} = RequestRegistry.get(id)
    RequestRegistry.delete(id)
  end

  test "another runtime incarnation cannot overwrite ownership or terminalize a request" do
    id = "owned-#{System.unique_integer([:positive])}"

    other =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(other, :stop) end)

    assert :ok = RequestRegistry.put(id, %{status: :running, runtime_pid: self()})

    assert {:error, :ownership_conflict} =
             RequestRegistry.put(id, %{status: :failed, runtime_pid: other})

    owner = self()
    assert {:ok, %{status: :running, runtime_pid: ^owner}} = RequestRegistry.get(id)
    RequestRegistry.delete(id)
  end

  test "concurrent updates retain independently recorded request fields" do
    id = "concurrent-#{System.unique_integer([:positive])}"
    owner = self()
    assert :ok = RequestRegistry.put(id, %{status: :running, runtime_pid: owner})

    tasks =
      for n <- 1..32 do
        Task.async(fn ->
          RequestRegistry.put(id, %{"field-#{n}" => n, runtime_pid: owner})
        end)
      end

    Enum.each(tasks, &assert(:ok == Task.await(&1)))
    assert {:ok, recorded} = RequestRegistry.get(id)
    for n <- 1..32, do: assert(recorded["field-#{n}"] == n)
    RequestRegistry.delete(id)
  end

  property "the first terminal disposition survives all later stream status updates" do
    check all(statuses <- list_of(member_of([:streaming, :completed, :failed, :cancelled]))) do
      id = "status-property-#{System.unique_integer([:positive])}"
      assert :ok = RequestRegistry.put(id, %{status: :running, runtime_pid: self()})

      Enum.reduce(statuses, :running, fn status, current ->
        result = RequestRegistry.put(id, %{status: status, runtime_pid: self()})

        expected =
          if current in [:completed, :failed, :cancelled] and status != current do
            assert result == {:error, :terminal_request}
            current
          else
            assert result == :ok
            status
          end

        assert {:ok, %{status: ^expected}} = RequestRegistry.get(id)
        expected
      end)

      assert :ok = RequestRegistry.delete(id)
    end
  end

  property "actor and execution scope cannot be reassigned by another update" do
    check all(person_id <- positive_integer(), scope <- string(:alphanumeric, min_length: 1)) do
      id = "scope-property-#{System.unique_integer([:positive])}"
      actor = %{person: %{id: person_id}}

      assert :ok =
               RequestRegistry.put(id, %{
                 actor: actor,
                 execution_scope: scope,
                 status: :running,
                 runtime_pid: self()
               })

      assert {:error, :ownership_conflict} =
               RequestRegistry.put(id, %{actor: %{person: %{id: person_id + 1}}})

      assert {:error, :ownership_conflict} =
               RequestRegistry.put(id, %{execution_scope: scope <> "-other"})

      assert {:ok, %{actor: ^actor, execution_scope: ^scope, status: :running}} =
               RequestRegistry.get(id)

      assert :ok = RequestRegistry.delete(id)
    end
  end

  test "get returns not_found when registry table is unavailable" do
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table)
    end

    assert {:error, :not_found} = RequestRegistry.get("missing-table-request")
  end

  defp ensure_registry_available! do
    case :ets.whereis(@table) do
      :undefined ->
        restart_or_start_registry()

      _table ->
        :ok
    end
  end

  defp restore_registry! do
    ensure_registry_available!()

    assert_registry_restored!()
  end

  defp restart_or_start_registry do
    case Process.whereis(RequestRegistry) do
      nil ->
        start_registry!()

      pid ->
        restart_registry_process(pid)
    end
  end

  defp restart_registry_process(pid) do
    Process.exit(pid, :kill)
    wait_for_table!(10)
    maybe_start_registry()
  end

  defp maybe_start_registry do
    if :ets.whereis(@table) == :undefined do
      start_registry!()
    end
  end

  defp start_registry! do
    {:ok, _pid} = RequestRegistry.start_link([])
  end

  defp assert_registry_restored! do
    if :ets.whereis(@table) == :undefined do
      flunk("expected request registry ETS table to be restored")
    end
  end

  defp wait_for_table!(0), do: :ok

  defp wait_for_table!(attempts) do
    if :ets.whereis(@table) == :undefined do
      Process.sleep(10)
      wait_for_table!(attempts - 1)
    else
      :ok
    end
  end
end
