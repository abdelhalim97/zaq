defmodule Zaq.Repro.NativeHttpToolCancellationTest do
  @moduledoc """
  Independent native cancellation defect; run explicitly with:
  mix test test/repro/native_http_tool_cancellation.exs

  Native completion reports failure while the real HTTP tool borrower survives.
  This is not a membership-retirement test. Only the external API/LLM are doubles.
  """
  # Deliberately opt-in: preserves an independent failing cancellation contract.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Executor
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.System, as: ZaqSystem
  alias Zaq.System.OutboundHttpPolicy
  alias Zaq.TestSupport.{IntegrationAgent, OpenAIStub, ToolCallingLLMStub}

  setup do
    owner = self()
    id = "native-cancel-#{Ecto.UUID.generate()}"

    {child, target} =
      OpenAIStub.server(
        fn _conn, _body ->
          send(owner, {:tool_http_barrier, self()})

          receive do
            :release_tool_http -> {200, %{"ok" => true}}
          after
            10_000 -> raise "tool HTTP barrier not released"
          end
        end,
        owner
      )

    start_supervised!(Supervisor.child_spec(child, id: :target_api))

    {:ok, _} =
      %OutboundHttpPolicy{}
      |> OutboundHttpPolicy.changeset(%{
        enabled: true,
        block_loopback: false,
        allowed_methods: ["GET"],
        allowed_ports: [URI.parse(target).port]
      })
      |> ZaqSystem.save_outbound_http_policy()

    {llm, endpoint} =
      ToolCallingLLMStub.server(
        [
          %{
            match: &String.contains?(&1, "Send GET to the test API"),
            tool: "http_request",
            arguments: fn _ -> %{method: "GET", url: target <> "/get"} end
          }
        ],
        max_interactions: 6,
        final_response: "HTTP completed"
      )

    start_supervised!(llm)

    agent =
      IntegrationAgent.create!(
        endpoint,
        id,
        "Send each requested HTTP call once and report its response.",
        ["general.http_request"]
      )

    {:ok, %{id: id, target: target, agent: agent}}
  end

  test "native cancellation terminates a pending real HTTP tool before acknowledging cleanup",
       context do
    owner = self()
    port = URI.parse(context.target).port
    handler = {__MODULE__, :cancellation, self()}

    :telemetry.attach(
      handler,
      [:finch, :queue, :stop],
      fn _, _, metadata, _ ->
        if metadata.request.port == port, do: send(owner, {:tool_http, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    execution =
      Task.async(fn ->
        incoming = %Incoming{
          content: "Send GET to the test API",
          channel_id: context.id,
          provider: :web
        }

        Executor.run(incoming,
          agent_id: to_string(context.agent.id),
          scope: context.id,
          event: Zaq.Event.new(incoming, :agent, actor: %{kind: :anonymous, subject: context.id})
        )
      end)

    assert_receive {:tool_http_barrier, worker}, 5_000
    on_exit(fn -> send(worker, :release_tool_http) end)
    assert_receive {:tool_http, http}, 5_000
    monitor = Process.monitor(http)

    pid =
      Jido.AgentServer.whereis(
        Jido.registry_name(Zaq.Agent.Jido),
        "#{context.agent.name}:#{context.id}"
      )

    {:ok, %{raw_state: %{__strategy__: state}}} = Jido.AgentServer.status(pid)
    request_id = state.active_request_id

    signal =
      Jido.Signal.new!(
        "ai.react.cancel",
        %{request_id: request_id, reason: :history_membership_removed},
        source: "/zaq/agent/history"
      )

    assert {:ok, _} = Jido.AgentServer.call(pid, signal, 5_000)

    assert {:ok, %{status: :failed}} =
             Jido.AgentServer.await_completion(pid,
               timeout: 5_000,
               status_path: [:requests, request_id, :status],
               result_path: [:requests, request_id, :result],
               error_path: [:requests, request_id, :error]
             )

    try do
      assert_receive {:DOWN, ^monitor, :process, ^http, _},
                     5_000,
                     "HTTP tool borrower survived native cancellation completion"
    after
      send(worker, :release_tool_http)
    end

    Task.await(execution, 5_000)
  end
end
