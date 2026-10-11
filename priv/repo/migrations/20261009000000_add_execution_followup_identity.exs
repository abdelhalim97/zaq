defmodule Zaq.Repo.Migrations.AddExecutionFollowupIdentity do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT user_message_id FROM execution_records
        WHERE root_execution_id IS NULL GROUP BY user_message_id HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'Conflicting execution roots require investigation; no historical rows were changed';
      END IF;
    END $$
    """)

    alter table(:execution_records) do
      add :recovered_from_execution_id,
          references(:execution_records, type: :binary_id, on_delete: :restrict)
    end

    create unique_index(:execution_records, [:recovered_from_execution_id])

    create unique_index(:execution_records, [:user_message_id],
             where: "root_execution_id IS NULL",
             name: :execution_records_input_root_index
           )

    create constraint(:execution_records, :execution_records_recovery_root_check,
             check:
               "recovered_from_execution_id IS NULL OR (root_execution_id IS NULL AND recovered_from_execution_id <> id)"
           )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM execution_records WHERE recovered_from_execution_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Cannot remove populated execution followup evidence';
      END IF;
    END $$
    """)

    drop constraint(:execution_records, :execution_records_recovery_root_check)
    drop index(:execution_records, [:user_message_id], name: :execution_records_input_root_index)
    drop index(:execution_records, [:recovered_from_execution_id])
    alter table(:execution_records), do: remove(:recovered_from_execution_id)
  end
end
