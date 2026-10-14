defmodule Zaq.Engine.Conversations.ExecutionLifecycleTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations.{Conversation, ExecutionLifecycle, ExecutionRecord, Message}
  alias Zaq.Repo

  test "explicit malformed execution IDs are unauthorized and leave input and execution unchanged" do
    {person, input, execution} = fixture()
    before_input = input
    before_execution = execution
    actor = actor(person)

    assert {:error, :unauthorized} = ExecutionLifecycle.accept_admission(input, "not-a-uuid")
    assert {:error, :unauthorized} = ExecutionLifecycle.authorize(input, actor, "not-a-uuid")

    assert {:error, :unauthorized} =
             ExecutionLifecycle.authorize_finalization(input, actor, "not-a-uuid")

    assert {:error, :unauthorized} =
             ExecutionLifecycle.finish(input, nil, "failed", [], %{}, %{}, "not-a-uuid")

    assert Repo.get!(Message, input.id) == before_input
    assert Repo.get!(ExecutionRecord, execution.id) == before_execution
  end

  test "authorization preserves input-only compatibility only when no execution exists" do
    {person, input, _execution} = fixture()
    legacy_input = message(input.conversation_id, "legacy")

    assert :ok = ExecutionLifecycle.authorize(legacy_input, actor(person))
    assert :ok = ExecutionLifecycle.authorize_finalization(legacy_input, actor(person))
  end

  test "consume rejects a missing-record root without changing the private child" do
    {_person, child, child_execution} = fixture()
    root_without_record = message(child.conversation_id, "legacy root")
    before = child_execution

    assert {:error, :unauthorized} =
             ExecutionLifecycle.consume(root_without_record, child,
               execution_id: child_execution.id
             )

    assert Repo.get!(ExecutionRecord, child_execution.id) == before
  end

  test "reject before linking returns input conflict and preserves both records" do
    {_person, root, root_execution} = fixture()
    {_person, child, child_execution} = fixture(root_execution.person_id)
    before_root = root_execution
    before_child = child_execution

    assert {:error, :input_conflict} = ExecutionLifecycle.reject(root, child, :scope_conflict)
    assert Repo.get!(ExecutionRecord, root_execution.id) == before_root
    assert Repo.get!(ExecutionRecord, child_execution.id) == before_child
  end

  test "followup requires admission before creating a new execution" do
    {_person, input, execution} = fixture()
    before = execution

    assert {:error, :admission_required} =
             ExecutionLifecycle.prepare_followup(
               input,
               %{receipt_execution_id: execution.id, root_execution_id: Ecto.UUID.generate()},
               actor(%{id: execution.person_id})
             )

    assert Repo.get!(ExecutionRecord, execution.id) == before
    assert Repo.aggregate(ExecutionRecord, :count) == 1
  end

  defp fixture(person_id \\ nil) do
    person =
      if person_id do
        Repo.get!(Zaq.Accounts.Person, person_id)
      else
        {:ok, person} = People.create_person(%{full_name: "Execution lifecycle"})
        person
      end

    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{channel_type: "api", person_id: person.id})
      |> Repo.insert()

    input = message(conversation.id, Ecto.UUID.generate())
    token_hash = :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode64()

    {:ok, execution} =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: person.id,
        user_message_id: input.id,
        finalization_token_hash: token_hash
      })
      |> Repo.insert()

    {person, input, execution}
  end

  defp message(conversation_id, content) do
    {:ok, message} =
      %Message{}
      |> Message.changeset(%{conversation_id: conversation_id, role: "user", content: content})
      |> Repo.insert()

    message
  end

  defp actor(person), do: %{person: %{id: person.id}}
end
