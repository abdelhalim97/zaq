defmodule Zaq.Agent.LiveRequestTargetTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent.{Api, Factory, RequestControl, ServerManager}
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  setup do
    owner = self()
    turn = :atomics.new(1, [])

    handler = fn _conn, body ->
      if :atomics.add_get(turn, 1, 1) == 1 do
        send(owner, {:target_model_waiting, self()})

        receive do
          :release_target_model -> :ok
        after
          10_000 -> flunk("target model barrier was not released")
        end
      end

      request = Jason.decode!(body)
      send(owner, {:target_model_request, request})
      {200, MultiAgentOpenAIStub.text_sse("Done", request["model"])}
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)

    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Live targeting #{System.unique_integer([:positive])}",
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        active: true,
        model_max_context_tokens: 20_000
      })

    actor = %{kind: :bo_user, subject: "target-owner"}
    scope = "live-target:#{Ecto.UUID.generate()}"
    assert {:ok, server} = ServerManager.ensure_server(agent, scope, nil, actor: actor)
    on_exit(fn -> ServerManager.stop_server(agent, scope) end)
    %{agent: agent, actor: actor, scope: scope, server: server, pid: GenServer.whereis(server)}
  end

  test "live targeting uses native identity without observing stream presentation", ctx do
    assert {:ok, %{request: request}} = Factory.ask_with_config(ctx.server, "Question", ctx.agent)
    assert_receive {:target_model_waiting, worker}, 5_000
    on_exit(fn -> send(worker, :release_target_model) end)

    assert {:ok, {id, target}} =
             RequestControl.find_native_request(ctx.scope, ctx.actor, %{agent_id: ctx.agent.id})

    assert id == request.id
    assert target.runtime_pid == ctx.pid
    assert target.actor == ctx.actor

    assert {:error, :not_found} =
             RequestControl.find_native_request(ctx.scope, %{kind: :bo_user, subject: "foreign"})

    assert {:error, :not_found} =
             RequestControl.find_native_request(ctx.scope <> "other", ctx.actor)

    assert {:error, :not_found} =
             RequestControl.find_native_request(ctx.scope, ctx.actor, %{
               agent_id: ctx.agent.id + 1
             })

    for action <- [:steer_request, :inject_request],
        actor <- [nil, %{kind: :bo_user, subject: "foreign"}] do
      event = Event.new(%{request_id: id, content: "Forbidden"}, :agent, actor: actor)
      assert %{response: {:error, :not_found}} = Api.handle_event(event, action, nil)
    end

    wrong_scope =
      Event.new(
        %{request_id: id, content: "Wrong", execution_scope: "other"},
        :agent,
        actor: ctx.actor
      )

    assert %{response: {:error, :scope_conflict}} =
             Api.handle_event(wrong_scope, :steer_request, nil)

    for action <- [:steer_request, :inject_request] do
      event =
        Event.new(%{request_id: id, content: "Correction #{action}"}, :agent, actor: ctx.actor)

      assert %{response: {:ok, _}} = Api.handle_event(event, action, nil)
    end

    assert {:ok, %{raw_state: raw}} = Jido.AgentServer.status(ctx.pid)
    assert raw.__strategy__.active_request_id == id
    assert raw.__strategy__.last_pending_input_control.request_id == id

    attachment = %Record{
      id: "steered-record",
      kind: :file,
      name: "correction.pdf",
      mime_type: "application/pdf",
      materialization_handle: "signed-steering-handle",
      raw: %{secret: "PRIVATE_RAW_ATTACHMENT"}
    }

    event = Event.new(%{request_id: id}, :agent, actor: ctx.actor)

    assert {:ok, _} =
             RequestControl.control(event, id, "Read the correction", :steer_request, nil,
               attachments: [attachment]
             )

    send(worker, :release_target_model)
    assert {:ok, "Done"} = Factory.await(request, timeout: 5_000)
    assert_receive {:target_model_request, _initial}, 5_000
    assert_receive {:target_model_request, corrected}, 5_000
    payload = Jason.encode!(corrected)
    assert length(Regex.scan(~r/correction\.pdf/, payload)) == 1
    assert payload =~ "Read the correction"
    assert payload =~ "Attachments:"
    refute payload =~ "PRIVATE_RAW_ATTACHMENT"
    refute payload =~ "signed-steering-handle"
    assert {:error, :not_found} = RequestControl.find_native_request(ctx.scope, ctx.actor)
    assert :ets.whereis(:zaq_agent_request_observations) == :undefined
  end

  test "a stale PID cannot select a replacement even with the same scope", ctx do
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)

    assert {:ok, replacement} =
             ServerManager.ensure_server(ctx.agent, ctx.scope, nil, actor: ctx.actor)

    refute GenServer.whereis(replacement) == ctx.pid
    assert {:ok, []} = ServerManager.runtime_candidates(ctx.actor, ctx.scope, ctx.pid)
  end

  property "live snapshots never match a foreign principal or another literal scope", ctx do
    assert {:ok, [candidate]} = ServerManager.runtime_candidates(ctx.actor, ctx.scope, ctx.pid)
    assert candidate.runtime_pid == ctx.pid

    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 40)) do
      assert {:ok, []} = ServerManager.runtime_candidates(ctx.actor, ctx.scope <> suffix, ctx.pid)
      actor = %{kind: :bo_user, subject: "foreign-" <> suffix}
      assert {:ok, []} = ServerManager.runtime_candidates(actor, ctx.scope, ctx.pid)
    end
  end
end
