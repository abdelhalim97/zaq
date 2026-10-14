unless Code.ensure_loaded?(Zaq.Repo.Migrations.NormalizePersonEmails) do
  Code.require_file(
    "../../../priv/repo/migrations/20260910194115_normalize_person_emails.exs",
    __DIR__
  )
end

defmodule Zaq.Accounts.PersonEmailDataMigrationTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties
  import Zaq.CommunicationFixtures
  @moduletag timeout: 600_000

  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Engine.{Conversations, IncomingMessageRoutingRule}
  alias Zaq.Repo.Migrations.NormalizePersonEmails

  @version 20_260_910_194_115

  setup do
    # Transactional DDL is restored by this serial DataCase's sandbox rollback.
    # No other test connection can see the legacy schema or its duplicate rows.
    Repo.query!("DROP INDEX IF EXISTS channels_platform_channel_identifier_index")
    Repo.query!("DROP INDEX IF EXISTS channels_connector_identifier_index")
    Repo.query!("ALTER TABLE channels ALTER COLUMN person_identity_id DROP NOT NULL")
    connector_fixture("email")

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS channels_person_id_platform_channel_identifier_index ON channels (person_id, platform, channel_identifier)"
    )

    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    :ok
  end

  test "mixed transitive channels and cross-field email identity merge one complete component" do
    first = legacy_person(" BRIDGE@example.com ")
    second = legacy_person(nil)
    third = legacy_person(nil)
    fourth = legacy_person("other@example.com")
    unrelated = legacy_person(nil)

    for {person_id, platform, identifier} <- [
          {second, "email", "bridge@example.com"},
          {second, "telegram", "Exact"},
          {third, "telegram", "Exact"},
          {third, "email", " OTHER@example.com "},
          {unrelated, "telegram", "exact"}
        ] do
      legacy_channel(%{
        person_id: person_id,
        platform: platform,
        channel_identifier: identifier
      })
    end

    assert :ok = migrate()
    assert People.get_person!(first).merged_person_ids == [second, third, fourth]
    assert People.get_person!(first).email == "bridge@example.com"
    assert People.get_person!(unrelated).id == unrelated

    assert Enum.sort(
             Enum.map(People.list_person_channels(first), &{&1.platform, &1.channel_identifier})
           ) ==
             [
               {"email", "bridge@example.com"},
               {"email", "other@example.com"},
               {"telegram", "Exact"}
             ]

    assert [[true]] =
             Repo.query!(
               "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_platform_channel_identifier_index'::regclass"
             ).rows
  end

  test "singleton channel-only identities deduplicate every platform without changing opaque IDs" do
    # Exact per-person duplicates require the historical constraint absent too.
    Repo.query!("DROP INDEX IF EXISTS channels_person_id_platform_channel_identifier_index")
    person = legacy_person(nil)

    winner_ids =
      for platform <- ["email", "telegram"] do
        identifier = if platform == "email", do: " SINGLE@example.com ", else: " Exact "

        first =
          legacy_channel(%{
            person_id: person,
            platform: platform,
            channel_identifier: identifier,
            weight: 7,
            metadata: %{"nested" => %{"keep" => false}},
            last_interaction_at: ~U[2020-01-01 00:00:00Z]
          })

        legacy_channel(%{
          person_id: person,
          platform: platform,
          channel_identifier: identifier,
          weight: 2,
          metadata: %{"nested" => %{"keep" => true, "fill" => "yes"}},
          last_interaction_at: ~U[2021-01-01 00:00:00Z]
        })

        first.id
      end

    assert :ok = migrate()
    assert People.get_person!(person).email == nil
    assert People.get_person!(person).merged_person_ids == []
    channels = People.list_person_channels(person)
    assert length(channels) == 2
    assert Enum.sort(Enum.map(channels, & &1.id)) == winner_ids

    for channel <- channels do
      assert channel.weight == 7
      assert channel.metadata == %{"nested" => %{"keep" => false, "fill" => "yes"}}
      assert channel.last_interaction_at == ~U[2021-01-01 00:00:00Z]

      assert channel.channel_identifier ==
               if(channel.platform == "email", do: "single@example.com", else: " Exact ")
    end
  end

  test "blank legacy channel identifiers fail explicitly without bridging people or recording migration" do
    for platform <- ["email", "telegram"] do
      person = legacy_person(nil)

      legacy_channel(%{
        person_id: person,
        platform: platform,
        channel_identifier: " \t"
      })
    end

    assert_raise Ecto.MigrationError, ~r/blank channel identifier/, &migrate/0
    assert Repo.aggregate(Person, :count) == 2

    assert Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [@version]).rows ==
             []

    assert Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows ==
             [[nil]]
  end

  test "real migrator applies three-way collision, delegates relationships and recorded rerun is a no-op" do
    first = legacy_person(" MIGRATION@example.com ", "First")
    second = legacy_person("Migration@example.com", "Second")
    third = legacy_person("migration@example.com", "Third")

    winner =
      legacy_channel(%{
        person_id: first,
        platform: "email",
        channel_identifier: " MIGRATION@example.com ",
        weight: 4,
        username: "kept",
        metadata: %{"nested" => %{"keep" => false, "fill" => " "}},
        last_interaction_at: ~U[2026-01-01 00:00:00Z]
      })

    legacy_channel(%{
      person_id: first,
      platform: "email",
      channel_identifier: "migration@example.com"
    })

    legacy_channel(%{
      person_id: second,
      platform: "email",
      channel_identifier: "Migration@example.com",
      username: "discarded",
      display_name: "Filled",
      phone: "123",
      dm_channel_id: "dm-filled",
      metadata: %{"nested" => %{"keep" => true, "fill" => "value"}},
      last_interaction_at: ~U[2026-03-01 00:00:00Z]
    })

    legacy_channel(%{
      person_id: third,
      platform: "email",
      channel_identifier: "migration@example.com"
    })

    {:ok, channel} =
      People.add_channel(
        scoped_channel_attrs(%{
          person_id: second,
          platform: "slack",
          channel_identifier: "migration"
        })
      )

    {:ok, conversation} =
      Conversations.create_conversation(%{person_id: third, channel_type: "slack"})

    assert :ok = migrate()
    survivor = People.get_person!(first)
    assert survivor.email == "migration@example.com"
    assert [email] = Enum.filter(People.list_person_channels(first), &(&1.platform == "email"))
    assert email.id == winner.id
    assert email.weight == 4
    assert email.username == "kept"
    assert email.display_name == "Filled"
    assert email.phone == "123"
    assert email.dm_channel_id == "dm-filled"
    assert email.metadata == %{"nested" => %{"keep" => false, "fill" => "value"}}
    assert email.last_interaction_at == ~U[2026-03-01 00:00:00Z]
    assert email.channel_identifier == "migration@example.com"
    assert survivor.merged_person_ids == [second, third]

    assert Enum.map(survivor.merge_history, &{&1["id"], &1["label"]}) ==
             [{second, "Second"}, {third, "Third"}]

    refute Repo.get(Person, second)
    assert People.get_person(third).id == first
    assert People.get_channel(channel.id).person_id == first
    assert Repo.get!(conversation.__struct__, conversation.id).person_id == first
    assert :already_up = migrate()
    assert People.get_person!(first) == survivor
    run_migration()
    assert People.get_person!(first) == survivor
    assert_raise Ecto.MigrationError, ~r/restore/, &NormalizePersonEmails.down/0
  end

  test "unexpected legacy unique violation raises and rolls back cleanup and the index ledger" do
    earlier = legacy_person(" EARLIER@example.com ")
    person = legacy_person(nil)

    for identifier <- [" LEGACY-BEFORE@example.com ", "legacy-blocked@example.com"] do
      legacy_channel(%{
        person_id: person,
        platform: "email",
        channel_identifier: identifier
      })
    end

    originals = Repo.all(from c in PersonChannel, order_by: c.id)

    # A database-side rewrite forces a real, undeclared old-index violation
    # during cleanup. The normal migrator must propagate it, not map or hide it.
    Repo.query!("""
    CREATE FUNCTION identity_legacy_collision() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN NEW.channel_identifier := 'legacy-blocked@example.com'; RETURN NEW; END $$
    """)

    Repo.query!("""
    CREATE TRIGGER identity_legacy_collision BEFORE UPDATE ON channels
    FOR EACH ROW WHEN (OLD.channel_identifier = ' LEGACY-BEFORE@example.com ')
    EXECUTE FUNCTION identity_legacy_collision()
    """)

    error = assert_raise Ecto.ConstraintError, &migrate/0
    assert error.constraint == "channels_person_id_platform_channel_identifier_index"
    assert Repo.get!(Person, earlier).email == " EARLIER@example.com "
    assert Repo.all(from c in PersonChannel, order_by: c.id) == originals

    assert Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows ==
             [[nil]]

    assert Repo.query!(
             "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_person_id_platform_channel_identifier_index'::regclass"
           ).rows == [[true]]

    assert Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [@version]).rows ==
             []
  end

  test "failed merge rolls back earlier groups and migration ledger" do
    singleton = legacy_person(" SINGLE@example.com ")
    merged = legacy_person(" EARLIER@example.com ")
    alias_id = legacy_person("retained-loser@example.com")

    for id <- [merged, alias_id] do
      legacy_channel(%{
        person_id: id,
        platform: "telegram",
        channel_identifier: "rollback-emails"
      })
    end

    original_channels = Repo.all(from c in PersonChannel, order_by: c.id)
    first = legacy_person("INVALID@example.com")
    second = legacy_person("invalid@example.com")
    Repo.insert!(%IncomingMessageRoutingRule{person_id: second, routing_mode: :agent})
    assert_raise Ecto.MigrationError, ~r/normalization failed/, &migrate/0
    assert Repo.get!(Person, singleton).email == " SINGLE@example.com "
    assert Repo.get!(Person, merged).email == " EARLIER@example.com "
    assert Repo.get!(Person, alias_id).merged_person_ids == []
    assert Repo.get!(Person, first).email == "INVALID@example.com"
    assert Repo.get!(Person, second).merged_person_ids == []
    assert Repo.all(from c in PersonChannel, order_by: c.id) == original_channels

    assert Repo.query!("SELECT to_regclass('channels_platform_channel_identifier_index')").rows ==
             [[nil]]

    assert [[true]] =
             Repo.query!(
               "SELECT indisunique FROM pg_index WHERE indexrelid = 'channels_person_id_platform_channel_identifier_index'::regclass"
             ).rows

    assert Repo.query!("SELECT version FROM schema_migrations WHERE version = $1", [@version]).rows ==
             []
  end

  property "migration and storage have the same Unicode canonical form and rerunning is idempotent" do
    check all(
            local <-
              list_of(member_of(["A", "Ä", "İ", "Σ", "ẞ", "é", "É"]),
                min_length: 1,
                max_length: 8
              ),
            padding <- member_of([" ", "\u00A0", "\u2003", "\r\n"]),
            max_runs: 15
          ) do
      email = padding <> Enum.join(local) <> "@EXAMPLE.COM" <> padding
      id = legacy_person(email)
      run_migration()

      expected =
        %Person{} |> Person.changeset(%{full_name: "Person", email: email}) |> get_field(:email)

      assert Repo.get!(Person, id).email == expected
      run_migration()
      assert Repo.get!(Person, id).email == expected
      Repo.delete!(Repo.get!(Person, id))
    end
  end

  test "normalizes singletons, does not merge blank emails, and keeps uniqueness" do
    ids = for email <- [nil, "", " \t\u2003", " SINGLE@Example.com "], do: legacy_person(email)
    run_migration()
    assert Enum.map(ids, &Repo.get!(Person, &1).email) == [nil, nil, nil, "single@example.com"]

    assert {:error, changeset} =
             People.create_person(%{full_name: "New", email: "Single@EXAMPLE.com"})

    assert errors_on(changeset).email == ["has already been taken"]
  end

  defp run_migration do
    # Remove only this version to exercise the data operation again, rather than
    # merely observing the migrator's already-applied short circuit.
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    Repo.query!("DROP INDEX IF EXISTS channels_platform_channel_identifier_index")
    assert :ok = migrate()
  end

  defp migrate do
    Ecto.Migrator.up(Repo, @version, NormalizePersonEmails,
      log: false,
      migration_lock: false,
      skip_table_creation: true
    )
  end

  defp legacy_person(email, name \\ "Person") do
    Repo.insert!(%Person{email: email, full_name: name}).id
  end

  defp legacy_channel(attrs) do
    config = connector_fixture(attrs.platform)
    Repo.insert!(struct(PersonChannel, Map.put(attrs, :channel_config_id, config.id)))
  end
end
