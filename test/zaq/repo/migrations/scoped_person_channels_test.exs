unless Code.ensure_loaded?(Zaq.Repo.Migrations.ScopePersonChannelsToConnector),
  do:
    Code.require_file(
      "priv/repo/migrations/20260922000003_scope_person_channels_to_connector.exs"
    )

unless Code.ensure_loaded?(Zaq.Repo.Migrations.CreatePersonIdentities),
  do: Code.require_file("priv/repo/migrations/20261002000001_create_person_identities.exs")

defmodule Zaq.Repo.Migrations.ScopedPersonChannelsTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonIdentities
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias Zaq.Repo.Migrations.{CreatePersonIdentities, ScopePersonChannelsToConnector}

  defmodule ConfiguredRoutingBridge do
    def incoming_routing(config),
      do: %{incoming?: config.settings["receiving"] == true, topics: []}
  end

  setup do
    Repo.query!(
      "ALTER TABLE channels ALTER COLUMN channel_config_id DROP NOT NULL, ALTER COLUMN person_identity_id DROP NOT NULL"
    )

    {:ok, person} = People.create_person(%{full_name: "Migrated owner"})
    %{person: person}
  end

  test "single disabled connector backfill preserves links and claims the scoped identity", %{
    person: person
  } do
    config = connector(false)
    id = legacy_channel(person)
    backfill()

    %{rows: [[^id, config_id, identity_id, owner_id]]} =
      Repo.query!(
        "SELECT c.id, c.channel_config_id, c.person_identity_id, i.person_id FROM channels c JOIN person_identities i ON i.id = c.person_identity_id WHERE c.id = $1",
        [id]
      )

    assert config_id == config.id
    assert owner_id == person.id
    assert is_integer(identity_id)
    backfill()
    assert {:ok, matched} = People.match_by_channel("discord", "123", config.id)
    assert matched.id == person.id
  end

  test "missing or ambiguous connector aborts without guessing", %{person: person} do
    legacy_channel(person)
    assert_raise RuntimeError, ~r/exactly one origin/, fn -> backfill() end
    connector(true)
    connector(false)
    assert_raise RuntimeError, ~r/exactly one origin/, fn -> backfill() end
  end

  test "profile email is backfilled to the default sender with native ownership", %{
    person: person
  } do
    Repo.query!("UPDATE people SET email = 'contact@example.com' WHERE id = $1", [person.id])
    backfill()

    assert {:ok, owner} =
             PersonIdentities.lookup("email", %{
               "channel_id" => "contact@example.com"
             })

    assert owner.id == person.id
    smtp = Repo.get_by!(ChannelConfig, provider: "email:smtp")
    assert [%{channel_config_id: id, platform: "email"}] = People.list_person_channels(person.id)
    assert id == smtp.id
    backfill()
    assert [_] = People.list_person_channels(person.id)
  end

  test "migration consults the configured bridge with stored settings, including archived origins",
       %{person: person} do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous, :discord, %{bridge: ConfiguredRoutingBridge})
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    connector(true)

    receiving =
      connector(false)
      |> Ecto.Changeset.change(
        settings: %{"receiving" => true},
        archived_at: ~U[2020-01-01 00:00:00Z]
      )
      |> Repo.update!()

    id = legacy_channel(person)

    ScopePersonChannelsToConnector.backfill(Repo)
    assert People.get_channel(id).channel_config_id == receiving.id
  end

  test "backfill never reinterprets an established native identity after an endpoint edit", %{
    person: person
  } do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Server",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://original.example.com",
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, channel} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "native-id",
        channel_config_id: config.id
      })

    config |> Ecto.Changeset.change(url: "https://different.example.com") |> Repo.update!()

    assert_raise RuntimeError, ~r/native identity scope changed/, fn ->
      backfill()
    end

    assert People.get_channel(channel.id).person_identity_id == channel.person_identity_id
  end

  test "legacy email links use a sole sending connector when there is no inbox", %{person: person} do
    Repo.delete_all(from(c in ChannelConfig, where: c.provider in ["email:imap", "email:smtp"]))

    smtp =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "SMTP origin",
        provider: "email:smtp",
        kind: "retrieval",
        url: "smtp://localhost",
        token: "test-token"
      })
      |> Repo.insert!()

    id = legacy_channel(person, "email", "legacy@example.com")
    backfill()
    channel = People.get_channel(id)
    assert channel.channel_config_id == smtp.id
    assert channel.weight == 7
    assert channel.person_identity_id
  end

  defp backfill do
    ScopePersonChannelsToConnector.backfill(Repo)
    CreatePersonIdentities.backfill(Repo)
  end

  defp legacy_channel(person, platform \\ "discord", identifier \\ "123") do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO channels (person_id, platform, channel_identifier, weight, inserted_at, updated_at) VALUES ($1, $2, $3, 7, NOW(), NOW()) RETURNING id",
        [person.id, platform, identifier]
      )

    id
  end

  defp connector(enabled) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      provider: "discord",
      kind: "retrieval",
      name: "Origin",
      enabled: enabled,
      url: "https://discord.example.com",
      token: "test-token"
    })
    |> Repo.insert!()
  end
end
