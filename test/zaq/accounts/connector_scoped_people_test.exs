defmodule Zaq.Accounts.ConnectorScopedPeopleTest do
  use Zaq.DataCase, async: true
  import Zaq.CommunicationFixtures

  alias Zaq.Accounts.{People, PersonIdentity}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver
  alias Zaq.Repo

  test "channel creation requires an explicit matching non-archived retrieval connector" do
    {:ok, person} = People.create_person(%{full_name: "Owner"})
    attrs = %{person_id: person.id, platform: "mattermost", channel_identifier: "native-id"}

    assert {:error, missing} = People.add_channel(attrs)
    assert "can't be blank" in errors_on(missing).channel_config_id
    assert People.list_person_channels(person.id) == []
    refute Repo.get_by(PersonIdentity, person_id: person.id)

    other = connector("discord")
    assert {:error, mismatch} = People.add_channel(Map.put(attrs, :channel_config_id, other.id))
    assert errors_on(mismatch).channel_config_id != []
    assert People.list_person_channels(person.id) == []
    refute Repo.get_by(PersonIdentity, person_id: person.id)

    disabled = connector("mattermost", enabled: false)
    assert {:ok, channel} = People.add_channel(Map.put(attrs, :channel_config_id, disabled.id))
    assert channel.channel_config_id == disabled.id
    assert channel.person_identity_id
  end

  test "connector binding is immutable and identity conflicts roll back" do
    {:ok, owner} = People.create_person(%{full_name: "Owner"})
    {:ok, other} = People.create_person(%{full_name: "Other"})
    config = connector("discord")
    second = connector("discord")
    attrs = %{platform: "discord", channel_identifier: "123", channel_config_id: config.id}
    assert {:ok, channel} = People.add_channel(Map.put(attrs, :person_id, owner.id))
    assert {:error, changeset} = People.update_channel(channel, %{channel_config_id: second.id})
    assert errors_on(changeset).channel_config_id != []
    assert {:error, _} = People.add_channel(Map.put(attrs, :person_id, other.id))
    assert People.list_person_channels(other.id) == []
  end

  test "profile email ownership is independent of connector links" do
    {:ok, owner} = People.create_person(%{full_name: "Profile owner", email: "owned@example.com"})
    {:ok, other} = People.create_person(%{full_name: "Other"})

    assert [%{platform: "email", person_identity_id: identity_id}] =
             People.list_person_channels(owner.id)

    assert identity_id

    assert {:error, _} =
             People.add_channel(%{
               person_id: other.id,
               platform: "email",
               channel_identifier: owner.email,
               channel_config_id: connector_fixture("email").id
             })
  end

  test "ingress without connector scope fails closed" do
    incoming =
      Incoming.new(%{content: "hello", provider: :discord, author_id: "123", channel_id: "room"})

    assert {:error, :connector_mismatch} = IdentityResolver.resolve(incoming, [])
  end

  defp connector(provider, attrs \\ []) do
    defaults =
      Map.new(
        Keyword.merge(
          [
            provider: provider,
            kind: "retrieval",
            name: "Connector",
            enabled: true,
            url: "https://#{System.unique_integer([:positive])}.example.com",
            token: "test-token"
          ],
          attrs
        )
      )

    %ChannelConfig{} |> ChannelConfig.changeset(defaults) |> Repo.insert!()
  end
end
