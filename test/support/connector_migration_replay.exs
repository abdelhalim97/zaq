# Exercises the unmerged connector/identity migrations from a populated pre-scope
# schema. Never point this replay at an existing development or test database.
partition = System.get_env("MIX_TEST_PARTITION", "")

unless Mix.env() == :test and Regex.match?(~r/^_c_upgrade[0-9]+$/, partition) do
  raise "Connector replay requires a fresh isolated _c_upgrade<number> test partition"
end

alias Zaq.Accounts.People
alias Zaq.Repo

unless String.ends_with?(Repo.config()[:database], partition),
  do: raise("Refusing to replay against a non-isolated database")

Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("db.extensions", ["--quiet"])
Logger.configure(level: :warning)

{:ok, _, _} =
  Ecto.Migrator.with_repo(Repo, fn repo ->
    path = Application.app_dir(:zaq, "priv/repo/migrations")
    Ecto.Migrator.run(repo, path, :up, to: 20_260_922_000_002, log: false)

    %{rows: [[scoped?]]} =
      repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'channels' AND column_name = 'channel_config_id')"
      )

    if scoped?,
      do:
        raise(
          "Replay database has already passed the pre-scope checkpoint; choose a fresh isolated partition"
        )

    %{rows: [[person_id]]} =
      repo.query!(
        "INSERT INTO people (full_name, email, inserted_at, updated_at) VALUES ('Legacy recipient', 'legacy@example.test', NOW(), NOW()) RETURNING id"
      )

    %{rows: [[origin_id]]} =
      repo.query!(~S"""
      INSERT INTO channel_configs (name, provider, kind, url, token, enabled, settings, inserted_at, updated_at)
      VALUES ('Disabled origin', 'email:imap', 'retrieval', 'imap://localhost', '', false,
        '{"imap":{"selected_mailboxes":["INBOX"]}}', NOW(), NOW()) RETURNING id
      """)

    %{rows: [[profile_id]]} =
      repo.query!(
        "INSERT INTO people (full_name, email, inserted_at, updated_at) VALUES ('Profile only', 'profile@example.test', NOW(), NOW()) RETURNING id"
      )

    repo.query!(
      "INSERT INTO channel_configs (name, provider, kind, url, token, enabled, inserted_at, updated_at) VALUES ('Sender', 'email:smtp', 'retrieval', 'smtp://localhost', '', true, NOW(), NOW()) ON CONFLICT (provider) DO UPDATE SET enabled = true"
    )

    %{rows: [[channel_id]]} =
      repo.query!(
        "INSERT INTO channels (person_id, platform, channel_identifier, weight, metadata, inserted_at, updated_at) VALUES ($1, 'email', 'legacy@example.test', 7, '{\"preserved\":true}', NOW(), NOW()) RETURNING id",
        [person_id]
      )

    Ecto.Migrator.run(repo, path, :up, all: true, log: false)

    %{rows: [[^channel_id, ^person_id, ^origin_id, 7, %{"preserved" => true}, identity_id]]} =
      repo.query!(
        "SELECT id, person_id, channel_config_id, weight, metadata, person_identity_id FROM channels WHERE id = $1",
        [channel_id]
      )

    true = is_integer(identity_id)
    {:ok, %{id: ^person_id}} = People.match_by_channel("email", "legacy@example.test", origin_id)

    %{rows: [[sender_id]]} =
      repo.query!(
        "SELECT id FROM channel_configs WHERE provider = 'email:smtp' AND notification_default"
      )

    [
      %{
        channel_config_id: ^sender_id,
        platform: "email",
        channel_identifier: "profile@example.test",
        person_identity_id: profile_identity_id
      }
    ] = People.list_person_channels(profile_id)

    true = is_integer(profile_identity_id)

    %{rows: nullability} =
      repo.query!(
        "SELECT column_name, is_nullable FROM information_schema.columns WHERE table_name = 'channels' AND column_name IN ('channel_config_id', 'person_identity_id') ORDER BY column_name"
      )

    [["channel_config_id", "NO"], ["person_identity_id", "NO"]] = nullability

    %{rows: [[nil]]} =
      repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')")

    %{rows: [[true, nil]]} =
      repo.query!(
        "SELECT indisunique, indpred::text FROM pg_index WHERE indexrelid = 'channels_connector_identifier_index'::regclass"
      )

    IO.puts(
      "Connector upgrade replay passed: origin, owner, preferences and IDs retained; strict constraints installed"
    )
  end)
