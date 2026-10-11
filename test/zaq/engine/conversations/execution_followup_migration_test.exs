unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddExecutionFollowupIdentity) do
  Code.require_file(
    "../../../../priv/repo/migrations/20261009000000_add_execution_followup_identity.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Conversations.ExecutionFollowupMigrationTest do
  use Zaq.DataCase, async: false
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Repo.Migrations.AddExecutionFollowupIdentity

  @version 20_261_009_000_000
  @opts [log: false, migration_lock: false, skip_table_creation: true]

  test "empty and populated root/receipt upgrades preserve evidence and refuse destructive rollback" do
    assert :ok = Ecto.Migrator.down(Repo, @version, AddExecutionFollowupIdentity, @opts)
    assert :ok = Ecto.Migrator.up(Repo, @version, AddExecutionFollowupIdentity, @opts)
    person = Repo.insert!(%Person{full_name: "Followup migration owner"})
    root = insert_execution(person, message("Root"), %{})
    input = message("Correction")
    receipt = insert_execution(person, input, %{root_execution_id: root.id, status: "unconsumed"})
    assert :ok = Ecto.Migrator.down(Repo, @version, AddExecutionFollowupIdentity, @opts)
    assert :ok = Ecto.Migrator.up(Repo, @version, AddExecutionFollowupIdentity, @opts)
    assert Repo.get!(ExecutionRecord, root.id) == root
    assert Repo.get!(ExecutionRecord, receipt.id) == receipt
    recovered = insert_execution(person, input, %{recovered_from_execution_id: receipt.id})

    assert_raise Postgrex.Error, ~r/Cannot remove populated execution followup evidence/, fn ->
      Ecto.Migrator.down(Repo, @version, AddExecutionFollowupIdentity, @opts)
    end

    assert Repo.get!(ExecutionRecord, receipt.id) == receipt
    assert Repo.get!(ExecutionRecord, recovered.id) == recovered
  end

  test "conflicting preexisting roots fail preflight without rewriting them" do
    person = Repo.insert!(%Person{full_name: "Preflight owner"})
    input = message("Input")
    root = insert_execution(person, input, %{})
    assert :ok = Ecto.Migrator.down(Repo, @version, AddExecutionFollowupIdentity, @opts)
    duplicate = Ecto.UUID.generate()
    {:ok, binary_id} = Ecto.UUID.dump(duplicate)
    {:ok, input_id} = Ecto.UUID.dump(input.id)
    hash = :crypto.hash(:sha256, duplicate) |> Base.encode64()

    Repo.query!(
      """
      INSERT INTO execution_records (id, person_id, user_message_id, status, finalization_token_hash, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'pending', $4, NOW(), NOW())
      """,
      [binary_id, person.id, input_id, hash]
    )

    assert_raise Postgrex.Error, ~r/Conflicting execution roots require investigation/, fn ->
      Ecto.Migrator.up(Repo, @version, AddExecutionFollowupIdentity, @opts)
    end

    assert %{rows: [[2]]} =
             Repo.query!("SELECT count(*) FROM execution_records WHERE user_message_id = $1", [
               input_id
             ])

    # Remove only this deliberately conflicting test fixture to restore the schema.
    Repo.query!("DELETE FROM execution_records WHERE id = $1", [binary_id])
    assert :ok = Ecto.Migrator.up(Repo, @version, AddExecutionFollowupIdentity, @opts)
    assert Repo.get!(ExecutionRecord, root.id) == root
  end

  defp message(content),
    do:
      %Message{}
      |> Message.canonical_changeset(%{role: "user", content: content})
      |> Repo.insert!()

  defp insert_execution(person, input, attrs) do
    %ExecutionRecord{}
    |> ExecutionRecord.changeset(
      Map.merge(
        %{
          person_id: person.id,
          user_message_id: input.id,
          finalization_token_hash: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode64(),
          trace_entries: [%{"private" => "preserved"}],
          usage: %{"prompt_tokens" => 9}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
