defmodule Zaq.Agent.RequestObservationTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Zaq.Agent.ServerManager

  test "bindings match literal principal, exact scope, agent and incarnation regardless of presentation" do
    id = unique_id()
    actor = %{person: %{id: 123}}
    on_exit(fn -> ServerManager.forget_request(id) end)

    assert :ok =
             ServerManager.observe_request(id, %{
               actor: actor,
               execution_scope: id,
               runtime_pid: self(),
               agent: %{id: 1},
               status: :tool_completed
             })

    assert {:ok, [{^id, _}]} = ServerManager.request_bindings(id, actor, self())
    assert {:ok, [{^id, _}]} = ServerManager.request_bindings(id, actor, %{agent_id: "1"})
    assert {:ok, []} = ServerManager.request_bindings(id, actor, %{agent_id: 2})
    assert {:ok, []} = ServerManager.request_bindings(id <> "other", actor)
    assert {:ok, []} = ServerManager.request_bindings(id, %{person: %{id: 124}})
    assert {:error, :not_found} = ServerManager.request_bindings(id, nil)

    assert :ok = ServerManager.observe_request(id, %{status: :completed})
    assert {:ok, [{^id, _}]} = ServerManager.request_bindings(id, actor)
  end

  test "another incarnation cannot overwrite ownership or terminalize a request" do
    id = unique_id()

    other =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      send(other, :stop)
      ServerManager.forget_request(id)
    end)

    assert :ok = ServerManager.observe_request(id, %{status: :running, runtime_pid: self()})

    assert {:error, :ownership_conflict} =
             ServerManager.observe_request(id, %{runtime_pid: other, status: :failed})

    assert {:ok, %{status: :running}} = ServerManager.request_observation(id)
  end

  test "serialized updates retain independent presentation fields" do
    id = unique_id()
    owner = self()
    on_exit(fn -> ServerManager.forget_request(id) end)
    assert :ok = ServerManager.observe_request(id, %{runtime_pid: owner})

    tasks =
      for n <- 1..32,
          do:
            Task.async(fn ->
              ServerManager.observe_request(id, %{"field-#{n}" => n, runtime_pid: owner})
            end)

    Enum.each(tasks, &assert(:ok == Task.await(&1)))
    assert {:ok, observed} = ServerManager.request_observation(id)
    for n <- 1..32, do: assert(observed["field-#{n}"] == n)
  end

  property "first terminal presentation survives later updates without changing ownership" do
    check all(
            statuses <-
              list_of(
                member_of([
                  :streaming,
                  :tool_running,
                  :tool_completed,
                  :completed,
                  :failed,
                  :cancelled
                ])
              ),
            person_id <- positive_integer(),
            scope <- string(:alphanumeric, min_length: 1)
          ) do
      id = unique_id()
      actor = %{person: %{id: person_id}}

      assert :ok =
               ServerManager.observe_request(id, %{
                 status: :running,
                 actor: actor,
                 execution_scope: scope
               })

      Enum.reduce(statuses, :running, fn status, current ->
        result = ServerManager.observe_request(id, %{status: status})

        expected =
          if current in [:completed, :failed, :cancelled] and status != current do
            assert result == {:error, :terminal_request}
            current
          else
            assert result == :ok
            status
          end

        assert {:ok, %{status: ^expected}} = ServerManager.request_observation(id)
        expected
      end)

      assert {:error, :ownership_conflict} =
               ServerManager.observe_request(id, %{actor: %{person: %{id: person_id + 1}}})

      assert {:error, :ownership_conflict} =
               ServerManager.observe_request(id, %{execution_scope: scope <> "other"})

      assert :ok = ServerManager.forget_request(id)
    end
  end

  test "history denial does not fabricate cancellation in delayed native observations" do
    id = unique_id()
    input = Ecto.UUID.generate()
    person = System.unique_integer([:positive])
    actor = %{person: %{id: person}}
    assert :ok = ServerManager.retire_history_scope(%{transcript_id: input, person_id: person})

    assert :ok =
             ServerManager.observe_request(id, %{
               actor: actor,
               runtime_pid: self(),
               status: :running,
               execution_scope: id
             })

    assert {:ok, %{status: :running} = observation} =
             ServerManager.request_observation(id)

    refute Map.has_key?(observation, :history_removed)
    assert {:ok, [{^id, _}]} = ServerManager.request_bindings(id, actor)
    assert :ok = ServerManager.observe_request(id, %{status: :completed})
    assert {:error, :terminal_request} = ServerManager.observe_request(id, %{status: :running})

    assert :ok = ServerManager.forget_request(id)
    assert {:error, :not_found} = ServerManager.request_observation(id)
  end

  test "missing or malformed IDs return the existing errors" do
    for id <- [nil, :id, 123] do
      assert {:error, :not_found} = ServerManager.request_observation(id)
      assert :ok = ServerManager.forget_request(id)
    end

    id = unique_id()
    assert :ok = ServerManager.observe_request(id, %{status: :streaming})
    assert :ok = ServerManager.forget_request(id)
    assert {:error, :not_found} = ServerManager.request_observation(id)
  end

  defp unique_id, do: "observation-#{System.unique_integer([:positive])}"
end
