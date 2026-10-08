defmodule Zaq.Engine.Conversations.ExecutionHistoryTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Agent.Api, as: AgentApi
  alias Zaq.Agent.RequestRegistry
  alias Zaq.Agent.StreamEvents
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryIngress}
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, Transcript}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Execution history",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://history.example.test",
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, alice} = People.create_person(%{full_name: "Alice"})
    {:ok, bob} = People.create_person(%{full_name: "Bob"})

    for {person, external} <- [{alice, "alice"}, {bob, "bob"}] do
      {:ok, _} =
        People.add_channel(%{
          person_id: person.id,
          platform: "mattermost",
          channel_identifier: external,
          channel_config_id: config.id
        })
    end

    %{config: config, alice: alice, bob: bob}
  end

  test "projects attributed root and local history once without current input or siblings", ctx do
    root = incoming(ctx, ctx.bob, "root", nil, "Project root")
    assert {:ok, _} = HistoryIngress.capture(root)
    grant(ctx)

    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "local", "root", "Local note"))

    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "sibling", "other-root", "FORBIDDEN"))

    question = incoming(ctx, ctx.alice, "question", "root", "Current input")
    assert {:ok, _} = HistoryIngress.capture(question)
    assert {:ok, binding} = Conversations.admit_incoming(question)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert projection.kind == :canonical
    assert Enum.map(projection.messages, & &1.content) == ["Project root", "Local note"]
    assert Enum.all?(projection.messages, &(&1.author_name == "Bob"))
    assert map_size(projection.cursors) == 2
    assert Enum.all?(projection.messages, &(not Map.has_key?(&1, :metadata)))
  end

  test "validates owner, literal active Person and admission capability before projection", ctx do
    {binding, _} = admitted(ctx)
    assert {:error, :unauthorized} = Conversations.execution_history(binding, nil)
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.bob))

    assert {:error, :unauthorized} =
             Conversations.execution_history(binding, %{person: %{id: 9_999_999}})

    assert {:error, :unauthorized} =
             Conversations.execution_history(
               %{binding | finalization_token: "forged"},
               actor(ctx.alice)
             )

    assert {:ok, _} = People.update_person(ctx.alice, %{status: "inactive"})
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.alice))
  end

  test "revocation on a later read denies access rather than falling back to private history",
       ctx do
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, ctx.bob, "root", nil, "Root"))
    {:ok, permission} = grant(ctx)
    {binding, _} = admitted(ctx, "root")
    assert {:ok, _} = Conversations.execution_history(binding, actor(ctx.alice))
    assert :ok = Permissions.revoke(resource(ctx), permission)
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.alice))
  end

  test "a missing root does not discard authorized thread replies", ctx do
    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "local", "missing-root", "Retained"))

    grant(ctx)
    {binding, _} = admitted(ctx, "missing-root")
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert Enum.map(projection.messages, & &1.content) == ["Retained"]
  end

  test "a transcript UUID cannot be substituted for the admitted input's conversation", ctx do
    {binding, _} = admitted(ctx)
    transcript = Repo.one!(from t in Transcript, where: is_nil(t.parent_id))
    forged = %{binding | conversation_id: transcript.id}
    assert {:error, :unauthorized} = Conversations.execution_history(forged, actor(ctx.alice))
  end

  test "Direct thread execution hydrates its shared parent transcript", ctx do
    root = incoming(ctx, ctx.alice, "direct-root", nil, "Direct note", :one_to_one)
    assert {:ok, _} = HistoryIngress.capture(root)
    input = incoming(ctx, ctx.alice, "direct-question", "direct-root", "Question", :one_to_one)
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert Enum.map(projection.messages, & &1.content) == ["Direct note"]
  end

  test "Replicated execution reads only the sender's authorized recipient copy", ctx do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Mail delivery",
      provider: "email:smtp",
      kind: "retrieval",
      enabled: true,
      url: "smtp://mail.test",
      token: "test-token"
    })
    |> Repo.insert!()

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Mail history",
        provider: "email:imap",
        kind: "retrieval",
        enabled: true,
        url: "imap://mail.test",
        token: "test-token",
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      })
      |> Repo.insert!()

    for {person, address} <- [{ctx.alice, "alice@test.example"}, {ctx.bob, "bob@test.example"}] do
      assert {:ok, _} =
               People.add_channel(%{
                 person_id: person.id,
                 platform: "email",
                 channel_identifier: address,
                 channel_config_id: config.id
               })
    end

    make = fn id, content ->
      Incoming.new(%{
        content: content,
        channel_id: "mail-thread",
        author_id: "alice@test.example",
        author_name: "Alice",
        message_id: id,
        person: ctx.alice,
        provider: :"email:imap",
        routing_context: %{
          channel_config_id: config.id,
          conversation_type: :recipient_addressed,
          topic_id: "INBOX",
          source_scope: "INBOX",
          identity_platform: "email",
          audience: %{
            platform: "email",
            sender: "alice@test.example",
            recipients: ["bob@test.example"]
          }
        }
      })
      |> CommunicationBridge.put_conversation_identity()
    end

    assert {:ok, _} = HistoryIngress.capture(make.("mail-root", "Mail note"))
    input = make.("mail-question", "Question")
    assert {:ok, capture} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert projection.transcript_id == capture.transcript_ids[ctx.alice.id]
    assert Enum.map(projection.messages, & &1.content) == ["Mail note"]
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.bob))
  end

  test "the Agent role rejects a forged capability before broadcasting request status", ctx do
    {binding, _} = admitted(ctx)
    session = "denied-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session}")
    input = incoming(ctx, ctx.alice, "question", nil, "Current input")
    input = %{input | metadata: Map.put(input.metadata, :session_id, session)}

    event =
      Event.new(input, :agent,
        actor: actor(ctx.alice),
        opts: [action: :run_pipeline]
      )

    event = %{
      event
      | assigns: %{"conversation_binding" => %{binding | finalization_token: "forged"}}
    }

    assert %{response: {:error, :unauthorized}, next_hop: nil} =
             AgentApi.handle_event(event, :run_pipeline, nil)

    refute_received {:status_update, _, _, _}
  end

  test "canonical admission creates one private root and finalization preserves public UUIDs",
       ctx do
    {binding, _} = admitted(ctx)
    execution = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
    assert execution.person_id == ctx.alice.id
    assert execution.status == "pending"
    refute execution.finalization_token_hash == binding.finalization_token

    result = %{
      answer: "Public answer",
      model: "test-model",
      prompt_tokens: 7,
      completion_tokens: 3,
      total_tokens: 10,
      trace: [%{"type" => "tool_call", "name" => "arithmetic.add", "result" => "PRIVATE_RESULT"}]
    }

    assert {:ok, finalized} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               result,
               actor: actor(ctx.alice)
             )

    assert {:ok, ^finalized} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               result,
               actor: actor(ctx.alice)
             )

    execution = Repo.get!(ExecutionRecord, execution.id)
    assert execution.status == "completed"
    assert execution.public_answer_message_id == finalized.assistant_message_id
    assert execution.usage["prompt_tokens"] == 7
    assert execution.trace_entries == result.trace
    assert execution.tool_results == result.trace
    answer = Repo.get!(Message, finalized.assistant_message_id)
    input = Repo.get!(Message, binding.user_message_id)
    assert answer.trace == []
    assert input.trace == []
    refute inspect(answer.metadata) =~ "PRIVATE_RESULT"
    assert answer.prompt_tokens == nil
    assert Repo.aggregate(ExecutionRecord, :count) == 1
  end

  test "foreign actor cannot finalize a private execution even with its capability", ctx do
    {binding, _} = admitted(ctx)

    assert {:error, :unauthorized} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{answer: "Denied"},
               actor: actor(ctx.bob)
             )

    assert Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id).status ==
             "pending"

    assert Repo.aggregate(Message, :count) == 1
  end

  test "failed canonical execution retains private diagnostics without a public answer", ctx do
    {binding, _} = admitted(ctx)

    assert {:ok, %{assistant_message_id: nil}} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{error: true, error_type: :timeout, trace: [%{"content" => "PRIVATE_FAILURE"}]},
               actor: actor(ctx.alice)
             )

    execution = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
    assert execution.status == "failed"
    assert execution.outcome["error_type"] == "timeout"
    assert execution.trace_entries == [%{"content" => "PRIVATE_FAILURE"}]
    assert Repo.get!(Message, binding.user_message_id).trace == []
  end

  test "request inspection revalidates the literal Person and current canonical grants", ctx do
    {binding, _} = admitted(ctx)
    {:ok, permission} = grant(ctx)
    request_id = "authorized-control-#{System.unique_integer([:positive])}"

    state = %{
      actor: actor(ctx.alice),
      execution_scope: "canonical-scope",
      status: :streaming,
      execution_user_message_id: binding.user_message_id,
      runtime_pid: self(),
      server_id: "private"
    }

    assert :ok = RequestRegistry.put(request_id, state)
    event = Event.new(%{request_id: request_id}, :agent, actor: actor(ctx.alice))
    assert %{response: {:ok, ^state}} = AgentApi.handle_event(event, :inspect_request, nil)
    unadmitted = %{event | request: %{request_id: request_id, content: "Unadmitted input"}}

    assert %{response: {:error, :admission_required}} =
             AgentApi.handle_event(unadmitted, :steer_request, nil)

    assert %{response: {:error, :unauthorized}} =
             AgentApi.handle_event(%{event | actor: actor(ctx.bob)}, :inspect_request, nil)

    assert :ok = Permissions.revoke(resource(ctx), permission)

    assert %{response: {:error, :unauthorized}} =
             AgentApi.handle_event(event, :inspect_request, nil)

    assert :ok = RequestRegistry.delete(request_id)
  end

  test "queued input is not consumption proof and root termination seals outstanding receipts",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    child_input = incoming(ctx, ctx.alice, "steering", nil, "Use this correction")
    assert {:ok, _} = HistoryIngress.capture(child_input)
    assert {:ok, child} = Conversations.admit_incoming(child_input)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    assert receipt.refs.message_id == child.user_message_id
    assert Repo.get!(ExecutionRecord, receipt.execution_id).status == "queued"

    assert {:ok, result} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Root answer"},
               actor: actor(ctx.alice)
             )

    record = Repo.get!(ExecutionRecord, receipt.execution_id)
    assert record.status == "unconsumed"
    assert record.public_answer_message_id == nil

    assert record.root_execution_id ==
             Repo.get_by!(ExecutionRecord, user_message_id: root.user_message_id).id

    assert {:error, :terminal_request} =
             Conversations.consume_execution_input(
               root.user_message_id,
               child.user_message_id,
               actor(ctx.alice)
             )

    assert result.assistant_message_id != nil
    assert Repo.aggregate(Message, :count) == 3
  end

  test "consumption is idempotent, private and never transfers the public answer", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "consumed", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    assert {:ok, _} =
             StreamEvents.consume(
               [
                 %{kind: :input_injected, data: %{refs: receipt.refs}}
               ],
               incoming(ctx, ctx.alice, "question", nil, "Current input"),
               actor: actor(ctx.alice),
               execution_user_message_id: root.user_message_id
             )

    assert :ok =
             Conversations.consume_execution_input(
               root.user_message_id,
               child.user_message_id,
               actor(ctx.alice)
             )

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "One answer"},
               actor: actor(ctx.alice)
             )

    assert Repo.get!(ExecutionRecord, receipt.execution_id).status == "consumed"
    assert Repo.get!(ExecutionRecord, receipt.execution_id).public_answer_message_id == nil

    assert {:error, :terminal_request} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))
  end

  test "an input losing the root-finalization race has a durable unconsumed disposition", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Already completed"},
               actor: actor(ctx.alice)
             )

    incoming = incoming(ctx, ctx.alice, "late-input", nil, "Late correction")
    assert {:ok, _} = HistoryIngress.capture(incoming)
    assert {:ok, child} = Conversations.admit_incoming(incoming)

    assert {:error, :terminal_request} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    record = Repo.get_by!(ExecutionRecord, user_message_id: child.user_message_id)
    assert record.status == "unconsumed"
    assert record.public_answer_message_id == nil
    assert record.outcome["reason"] == "terminal_request"

    assert {:error, :terminal_request} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    assert Repo.get!(ExecutionRecord, record.id) == record
    assert Repo.aggregate(Message, :count) == 3
  end

  test "terminal-input disposition cannot be forged by a foreign actor or invalid capability",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Completed"},
               actor: actor(ctx.alice)
             )

    input = incoming(ctx, ctx.alice, "forged-late", nil, "Late correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    before = Repo.get_by!(ExecutionRecord, user_message_id: child.user_message_id)

    assert {:error, :unauthorized} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.bob))

    assert {:error, :unauthorized} =
             Conversations.queue_execution_input(
               root.user_message_id,
               %{child | finalization_token: "forged"},
               actor(ctx.alice)
             )

    assert Repo.get!(ExecutionRecord, before.id) == before
  end

  defp admitted(ctx, thread \\ nil) do
    input = incoming(ctx, ctx.alice, "question", thread, "Current input")
    assert {:ok, capture} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    {binding, capture}
  end

  defp incoming(ctx, person, id, thread, content, type \\ :room) do
    Incoming.new(%{
      content: content,
      channel_id: "room",
      author_id: String.downcase(person.full_name),
      author_name: person.full_name,
      message_id: id,
      provider: :mattermost,
      person: person,
      thread_id: thread,
      routing_context: %{
        channel_config_id: ctx.config.id,
        conversation_type: type,
        thread_id: thread
      }
    })
    |> CommunicationBridge.put_conversation_identity()
  end

  defp actor(person), do: %{person: %{id: person.id}}
  defp resource(ctx), do: ChannelHistoryResource.for("mattermost", ctx.config.id, "room")

  defp grant(ctx),
    do: Permissions.grant(resource(ctx), %{person_id: ctx.alice.id, access_rights: ["read"]})
end
