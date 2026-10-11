unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddExecutionInputReceipts) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261008000000_add_execution_input_receipts.exs",
    __DIR__
  )
end

unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddExecutionFollowupIdentity) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261009000000_add_execution_followup_identity.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Conversations.ExecutionInputReceiptsMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Repo.Migrations.AddExecutionFollowupIdentity
  alias Zaq.Repo.Migrations.AddExecutionInputReceipts

  @version 20_261_008_000_000
  @opts [log: false, migration_lock: false, skip_table_creation: true]

  test "empty and populated-root upgrades preserve UUIDs, capabilities and private payloads" do
    round_trip()

    person = Repo.insert!(%Person{full_name: "Migration owner"})
    input = message("Root input")
    root = insert_execution(person, input, %{})

    round_trip()
    assert Repo.get!(ExecutionRecord, root.id) == root

    child =
      insert_execution(person, message("Child input"), %{
        root_execution_id: root.id,
        status: "queued"
      })

    assert :ok =
             Ecto.Migrator.down(Repo, @version + 1_000_000, AddExecutionFollowupIdentity, @opts)

    assert_raise Postgrex.Error, ~r/Cannot remove populated execution input receipts/, fn ->
      Ecto.Migrator.down(Repo, @version, AddExecutionInputReceipts, @opts)
    end

    assert :ok = Ecto.Migrator.up(Repo, @version + 1_000_000, AddExecutionFollowupIdentity, @opts)

    assert Repo.get!(ExecutionRecord, child.id) == child
    assert Repo.get!(ExecutionRecord, root.id) == root
  end

  defp round_trip do
    assert :ok =
             Ecto.Migrator.down(Repo, @version + 1_000_000, AddExecutionFollowupIdentity, @opts)

    assert :ok = Ecto.Migrator.down(Repo, @version, AddExecutionInputReceipts, @opts)
    assert :ok = Ecto.Migrator.up(Repo, @version, AddExecutionInputReceipts, @opts)
    assert :ok = Ecto.Migrator.up(Repo, @version + 1_000_000, AddExecutionFollowupIdentity, @opts)
  end

  defp message(content) do
    %Message{} |> Message.canonical_changeset(%{role: "user", content: content}) |> Repo.insert!()
  end

  defp insert_execution(person, input, overrides) do
    attrs = %{
      person_id: person.id,
      user_message_id: input.id,
      finalization_token_hash: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode64(),
      trace_entries: [%{"private" => "preserved"}],
      usage: %{"prompt_tokens" => 9}
    }

    %ExecutionRecord{} |> ExecutionRecord.changeset(Map.merge(attrs, overrides)) |> Repo.insert!()
  end
end
