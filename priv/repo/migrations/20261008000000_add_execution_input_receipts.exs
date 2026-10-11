defmodule Zaq.Repo.Migrations.AddExecutionInputReceipts do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT user_message_id FROM execution_records
        GROUP BY user_message_id HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'Conflicting execution roots require investigation; no historical rows were changed';
      END IF;
    END $$
    """)

    alter table(:execution_records) do
      add :root_execution_id,
          references(:execution_records, type: :binary_id, on_delete: :restrict)

      add :recovered_from_execution_id,
          references(:execution_records, type: :binary_id, on_delete: :restrict)

      add :admitted_at, :utc_datetime_usec
    end

    create index(:execution_records, [:root_execution_id, :status])
    create unique_index(:execution_records, [:recovered_from_execution_id])

    create unique_index(:execution_records, [:user_message_id],
             where: "root_execution_id IS NULL",
             name: :execution_records_input_root_index
           )

    create constraint(:execution_records, :execution_records_recovery_root_check,
             check:
               "recovered_from_execution_id IS NULL OR (root_execution_id IS NULL AND recovered_from_execution_id <> id)"
           )

    drop constraint(:execution_records, :execution_records_status_check)
    drop constraint(:execution_records, :execution_records_answer_status_check)

    create constraint(:execution_records, :execution_records_status_check,
             check:
               "status IN ('pending', 'completed', 'failed', 'queued', 'consumed', 'unconsumed')"
           )

    create constraint(:execution_records, :execution_records_answer_status_check,
             check:
               "(status = 'completed' AND public_answer_message_id IS NOT NULL) OR (status <> 'completed' AND public_answer_message_id IS NULL)"
           )

    create constraint(:execution_records, :execution_records_root_status_check,
             check:
               "(root_execution_id IS NULL AND status IN ('pending', 'completed', 'failed')) OR (root_execution_id IS NOT NULL AND root_execution_id <> id AND status IN ('queued', 'consumed', 'unconsumed'))"
           )
  end

  def down do
    # Keep the same audit-preservation policy as the original execution migration.
    # Populated roots can roll back; receipt-bearing databases cannot lose evidence.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM execution_records WHERE recovered_from_execution_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Cannot remove populated execution followup evidence';
      END IF;
      IF EXISTS (SELECT 1 FROM execution_records WHERE root_execution_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Cannot remove populated execution input receipts';
      END IF;
    END $$
    """)

    drop constraint(:execution_records, :execution_records_recovery_root_check)
    drop index(:execution_records, [:user_message_id], name: :execution_records_input_root_index)
    drop index(:execution_records, [:recovered_from_execution_id])
    drop constraint(:execution_records, :execution_records_root_status_check)
    drop constraint(:execution_records, :execution_records_answer_status_check)
    drop constraint(:execution_records, :execution_records_status_check)
    drop index(:execution_records, [:root_execution_id, :status])

    alter table(:execution_records) do
      remove :root_execution_id
      remove :recovered_from_execution_id
      remove :admitted_at
    end

    create constraint(:execution_records, :execution_records_status_check,
             check: "status IN ('pending', 'completed', 'failed')"
           )

    create constraint(:execution_records, :execution_records_answer_status_check,
             check:
               "(status = 'completed' AND public_answer_message_id IS NOT NULL) OR (status IN ('pending', 'failed') AND public_answer_message_id IS NULL)"
           )
  end
end
