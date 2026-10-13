defmodule Zaq.Engine.Conversations.PrivateChannelConcurrencyTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.{ChannelConfig, Conversations}
  alias Zaq.Engine.Conversations.{Conversation, ExecutionRecord, Message}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver

  test "concurrent trusted preparations bind one chat and cannot seed twice" do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Concurrent private chat",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert!()

    scope = %{
      provider: config.provider,
      channel_config_id: config.id,
      sender_id: "concurrent-sender"
    }

    assert {:ok, person} = IdentityResolver.resolve_channel_sender(scope)

    incoming =
      Incoming.new(%{
        provider: :web_widget,
        author_id: scope.sender_id,
        content: "Question",
        channel_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        routing_context: %{channel_config_id: config.id, conversation_type: :one_to_one}
      })
      |> CommunicationBridge.put_conversation_identity()

    tasks =
      Enum.map(["First context", "Second context"], fn context ->
        task =
          Task.async(fn ->
            receive do
              :go -> Conversations.prepare_channel_input(person, incoming, context)
            end
          end)

        task
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:ok, first}, {:ok, second}] = results
    assert first.routing_context.conversation_id == second.routing_context.conversation_id
    assert Repo.aggregate(Conversation, :count) == 1
    assert [%Message{content: context}] = Repo.all(Message)
    assert context in ["First context", "Second context"]
    assert Repo.aggregate(ExecutionRecord, :count) == 0
    assert {:ok, binding} = Conversations.admit_incoming(first)
    assert binding.conversation_id == first.routing_context.conversation_id
  end
end
