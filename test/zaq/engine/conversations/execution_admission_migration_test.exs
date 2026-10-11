unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddExecutionAdmissionTimestamp) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261010100852_add_execution_admission_timestamp.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Conversations.ExecutionAdmissionMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Repo.Migrations.AddExecutionAdmissionTimestamp

  @version 20_261_010_100_852
  @opts [log: false, migration_lock: false, skip_table_creation: true]

  test "rollback and reapply preserve private execution data without inventing admission" do
    person = Repo.insert!(%Person{full_name: "Admission migration owner"})

    input =
      %Message{}
      |> Message.canonical_changeset(%{role: "user", content: "Unapproved factual input"})
      |> Repo.insert!()

    execution =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: person.id,
        user_message_id: input.id,
        finalization_token_hash: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode64(),
        usage: %{"prompt_tokens" => 9},
        trace_entries: [%{"private" => "preserved"}]
      })
      |> Repo.insert!()

    assert :ok = Ecto.Migrator.down(Repo, @version, AddExecutionAdmissionTimestamp, @opts)
    assert :ok = Ecto.Migrator.up(Repo, @version, AddExecutionAdmissionTimestamp, @opts)
    assert Repo.get!(ExecutionRecord, execution.id) == execution
    assert Repo.get!(Message, input.id) == input
    assert is_nil(Repo.get!(ExecutionRecord, execution.id).admitted_at)
  end
end
