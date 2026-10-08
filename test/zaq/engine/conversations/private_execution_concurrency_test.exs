defmodule Zaq.Engine.Conversations.PrivateExecutionConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, PersonChannel}
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryIngress}

  alias Zaq.Engine.Conversations.{
    Conversation,
    ExecutionRecord,
    Message,
    Transcript,
    TranscriptMessage
  }

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.Repo

  setup do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        config =
          %ChannelConfig{}
          |> ChannelConfig.changeset(%{
            name: "Private execution locks",
            provider: "mattermost",
            kind: "retrieval",
            enabled: true,
            url: "https://execution-locks.example.test",
            token: "test-token"
          })
          |> Repo.insert!()

        {:ok, person} = People.create_person(%{full_name: "Execution lock owner"})

        {:ok, _} =
          People.add_channel(%{
            person_id: person.id,
            platform: "mattermost",
            channel_identifier: "lock-owner",
            channel_config_id: config.id
          })

        channel = "private-locks-#{Ecto.UUID.generate()}"
        resource = ChannelHistoryResource.for("mattermost", config.id, channel)

        {:ok, permission} =
          Permissions.grant(resource, %{person_id: person.id, access_rights: ["read"]})

        fixture = %{
          config: config,
          person: person,
          channel: channel,
          resource: resource,
          permission: permission,
          actor: %{person: %{id: person.id}}
        }

        root = admit(fixture, "Root")
        child = admit(fixture, "Correction")
        Map.merge(fixture, %{root: root, child: child})
      end)

    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> cleanup(fixture) end) end)
    fixture
  end

  for contender <- [:finalize, :queue, :consume] do
    test "private root finalization fences #{contender} on an independent database connection",
         fixture do
      contender = unquote(contender)
      prepare_contender(contender, fixture)

      parent = self()
      barrier = make_ref()

      writer =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            handler = {__MODULE__, barrier}

            :telemetry.attach(handler, [:zaq, :repo, :query], &__MODULE__.pause_root/4, %{
              owner: self(),
              parent: parent,
              barrier: barrier
            })

            try do
              finalize(fixture)
            after
              :telemetry.detach(handler)
            end
          end)
        end)

      try do
        assert_receive {:root_locked, ^barrier}, 5_000
        Sandbox.unboxed_run(Repo, fn -> assert_blocked(contender, fixture) end)
        send(writer.pid, {:resume, barrier})
        assert {:ok, finalized} = Task.await(writer, 5_000)

        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, ^finalized} = finalize(fixture)
          root = Repo.get_by!(ExecutionRecord, user_message_id: fixture.root.user_message_id)
          assert root.status == "completed"
          assert root.public_answer_message_id == finalized.assistant_message_id

          assert Repo.aggregate(
                   from(m in Message,
                     where:
                       m.conversation_id == ^fixture.root.conversation_id and
                         m.role == "assistant"
                   ),
                   :count
                 ) == 1

          assert Repo.get!(Message, fixture.child.user_message_id).content == "Correction"
          assert_terminal_input(contender, fixture, root)
        end)
      after
        send(writer.pid, {:resume, barrier})
        Task.shutdown(writer)
      end
    end
  end

  defp prepare_contender(:consume, fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} =
               Conversations.queue_execution_input(
                 fixture.root.user_message_id,
                 fixture.child,
                 fixture.actor
               )
    end)
  end

  defp prepare_contender(_contender, _fixture), do: :ok

  test "a real unavailable history read returns a safe error and leaves its fixed cursor reusable",
       fixture do
    initial =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, projection} = Conversations.execution_history(fixture.root, fixture.actor)
        projection
      end)

    parent = self()
    barrier = make_ref()

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("LOCK TABLE transcript_messages IN ACCESS EXCLUSIVE MODE")
            send(parent, {:history_locked, barrier})

            receive do
              {:resume, ^barrier} -> :ok
            after
              5_000 -> raise "History read barrier was not released"
            end
          end)
        end)
      end)

    try do
      assert_receive {:history_locked, ^barrier}, 5_000

      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SET lock_timeout = '100ms'")

        try do
          assert {:error, :history_unavailable} =
                   Conversations.execution_history(
                     fixture.root,
                     fixture.actor,
                     after_cursors: initial.cursors
                   )
        after
          Repo.query!("RESET lock_timeout")
        end
      end)

      send(writer.pid, {:resume, barrier})
      assert {:ok, :ok} = Task.await(writer, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, delta} =
                 Conversations.execution_history(fixture.root, fixture.actor,
                   after_cursors: initial.cursors
                 )

        assert delta.messages == []
        assert delta.cursors == initial.cursors
      end)
    after
      send(writer.pid, {:resume, barrier})
      Task.shutdown(writer)
    end
  end

  defp assert_blocked(:finalize, fixture) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '100ms'")
          finalize(fixture)
        end)
      end

    assert error.postgres.code == :lock_not_available
  end

  defp assert_blocked(contender, fixture) do
    assert {:ok, {:error, :execution_persistence_failed}} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL lock_timeout = '100ms'")
               input_operation(contender, fixture)
             end)
  end

  defp assert_terminal_input(:finalize, _fixture, _root), do: :ok

  defp assert_terminal_input(contender, fixture, root) do
    assert {:error, :terminal_request} = input_operation(contender, fixture)
    child = Repo.get_by!(ExecutionRecord, user_message_id: fixture.child.user_message_id)
    assert child.status == "unconsumed"
    assert child.root_execution_id == root.id
    assert child.public_answer_message_id == nil
  end

  defp input_operation(:queue, fixture),
    do:
      Conversations.queue_execution_input(
        fixture.root.user_message_id,
        fixture.child,
        fixture.actor
      )

  defp input_operation(:consume, fixture),
    do:
      Conversations.consume_execution_input(
        fixture.root.user_message_id,
        fixture.child.user_message_id,
        fixture.actor
      )

  defp finalize(fixture),
    do:
      Conversations.finalize_incoming(
        fixture.root.user_message_id,
        fixture.root.finalization_token,
        %{answer: "One locked answer", prompt_tokens: 7, completion_tokens: 3},
        actor: fixture.actor
      )

  defp admit(fixture, content) do
    input =
      Incoming.new(%{
        content: content,
        channel_id: fixture.channel,
        author_id: "lock-owner",
        message_id: Ecto.UUID.generate(),
        provider: :mattermost,
        person: fixture.person,
        routing_context: %{channel_config_id: fixture.config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    binding
  end

  defp cleanup(fixture) do
    ids = [fixture.root.user_message_id, fixture.child.user_message_id]

    Repo.delete_all(
      from e in ExecutionRecord,
        where: e.user_message_id in ^ids and not is_nil(e.root_execution_id)
    )

    Repo.delete_all(from e in ExecutionRecord, where: e.user_message_id in ^ids)

    transcript_ids =
      Repo.all(
        from t in Transcript, where: t.channel_config_id == ^fixture.config.id, select: t.id
      )

    Repo.delete_all(from p in TranscriptMessage, where: p.transcript_id in ^transcript_ids)
    Repo.delete_all(from t in Transcript, where: t.id in ^transcript_ids)
    Repo.delete_all(from c in Conversation, where: c.id == ^fixture.root.conversation_id)
    assert :ok = Permissions.revoke(fixture.resource, fixture.permission)
    Repo.delete_all(from c in PersonChannel, where: c.person_id == ^fixture.person.id)
    Repo.delete!(fixture.person)
    Repo.delete!(fixture.config)
  end

  @doc "Pauses after the real admitted-message row lock, before any finalization writes."
  def pause_root(_, _, %{query: query}, config) do
    if self() == config.owner and String.contains?(query, "FROM \"messages\"") and
         String.contains?(query, "FOR UPDATE") do
      send(config.parent, {:root_locked, config.barrier})

      receive do
        {:resume, barrier} when barrier == config.barrier -> :ok
      after
        10_000 -> raise "Root lock barrier was not released"
      end
    end
  end
end
