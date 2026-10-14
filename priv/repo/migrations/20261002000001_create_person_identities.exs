defmodule Zaq.Repo.Migrations.CreatePersonIdentities do
  use Ecto.Migration

  def up do
    create table(:person_identities) do
      add :platform, :string, null: false
      add :authority, :text, null: false
      add :identifier, :text, null: false
      add :person_id, references(:people, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:person_identities, [:platform, :authority, :identifier])
    create index(:person_identities, [:person_id])

    alter table(:channels) do
      add :person_identity_id, references(:person_identities, on_delete: :nothing)
    end

    create index(:channels, [:person_identity_id])
    flush()
    backfill(repo())

    alter table(:channels) do
      modify :person_identity_id, :bigint, null: false
    end
  end

  def backfill(repo) do
    repo.query!(
      "LOCK TABLE people, channels, channel_configs, person_identities IN SHARE ROW EXCLUSIVE MODE"
    )

    %{rows: channels} =
      repo.query!("""
      SELECT c.id, c.platform, c.channel_identifier, c.person_id, cc.id, cc.url, c.person_identity_id
      FROM channels c JOIN channel_configs cc ON cc.id = c.channel_config_id
      ORDER BY c.id
      """)

    Enum.each(channels, fn [id, platform, identifier, person_id, config_id, url, previous_id] ->
      authority = Zaq.Channels.IdentityScope.authority(platform, %{id: config_id, url: url})

      if previous_id do
        %{rows: stored} =
          repo.query!(
            "SELECT platform, authority, identifier, person_id FROM person_identities WHERE id = $1",
            [previous_id]
          )

        unless stored == [[platform, authority, identifier, person_id]],
          do: raise("Existing native identity scope changed for PersonChannel #{id}")
      end

      identity_id = claim!(repo, platform, authority, identifier, person_id)
      repo.query!("UPDATE channels SET person_identity_id = $1 WHERE id = $2", [identity_id, id])
    end)

    %{rows: profiles} =
      repo.query!("SELECT id, email FROM people WHERE email IS NOT NULL ORDER BY id")

    Enum.each(profiles, fn [person_id, email] ->
      email = Zaq.Accounts.Person.normalize_email(email)

      if email do
        identity_id = claim!(repo, "email", "global", email, person_id)
        link_profile_email!(repo, person_id, email, identity_id)
      end
    end)
  end

  defp link_profile_email!(repo, person_id, email, identity_id) do
    %{rows: [[linked?]]} =
      repo.query!(
        "SELECT EXISTS (SELECT 1 FROM channels WHERE person_id = $1 AND platform = 'email' AND channel_identifier = $2)",
        [person_id, email]
      )

    unless linked? do
      %{rows: configs} =
        repo.query!("""
        SELECT id, notification_default FROM channel_configs
        WHERE provider = 'email:smtp' AND kind = 'retrieval' AND archived_at IS NULL
        ORDER BY id
        """)

      defaults = Enum.filter(configs, fn [_, default?] -> default? end)
      candidates = if defaults == [], do: configs, else: defaults

      config_id =
        case candidates do
          [[id, _]] -> id
          _ -> raise "Person #{person_id} email requires an unambiguous default SMTP connector"
        end

      repo.query!(
        """
        INSERT INTO channels (person_id, platform, channel_identifier, channel_config_id, person_identity_id, weight, inserted_at, updated_at)
        SELECT $1, 'email', $2, $3, $4, COALESCE(MAX(weight) + 1, 0), NOW(), NOW()
        FROM channels WHERE person_id = $1
        """,
        [person_id, email, config_id, identity_id]
      )
    end
  end

  defp claim!(repo, platform, authority, identifier, person_id) do
    repo.query!(
      """
      INSERT INTO person_identities (platform, authority, identifier, person_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, NOW(), NOW())
      ON CONFLICT (platform, authority, identifier) DO NOTHING
      """,
      [platform, authority, identifier, person_id]
    )

    %{rows: [[id, owner_id]]} =
      repo.query!(
        "SELECT id, person_id FROM person_identities WHERE platform = $1 AND authority = $2 AND identifier = $3",
        [platform, authority, identifier]
      )

    if owner_id != person_id,
      do: raise("Conflicting native identity owner for Person #{person_id}")

    id
  end

  def down do
    drop index(:channels, [:person_identity_id])

    alter table(:channels) do
      remove :person_identity_id
    end

    drop table(:person_identities)
  end
end
