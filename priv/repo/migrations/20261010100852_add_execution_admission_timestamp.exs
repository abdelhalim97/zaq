defmodule Zaq.Repo.Migrations.AddExecutionAdmissionTimestamp do
  use Ecto.Migration

  def change do
    alter table(:execution_records) do
      add :admitted_at, :utc_datetime_usec
    end
  end
end
