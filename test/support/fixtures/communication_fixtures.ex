defmodule Zaq.CommunicationFixtures do
  @moduledoc "Explicit communication connectors for People test fixtures."

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo

  def connector_fixture(platform) do
    provider =
      case to_string(platform) do
        email when email in ["email", "email:imap", "email:smtp"] -> "email:imap"
        other -> other
      end

    Repo.get_by(ChannelConfig, provider: provider, kind: "retrieval") ||
      Repo.insert!(%ChannelConfig{
        name: "#{platform} fixture",
        provider: provider,
        kind: "retrieval",
        url: "https://#{platform}.example.com",
        token: "",
        enabled: true,
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      })
  end

  def scoped_channel_attrs(attrs) do
    platform = attrs[:platform] || attrs["platform"]

    if Map.has_key?(attrs, "platform") do
      Map.put_new_lazy(attrs, "channel_config_id", fn -> connector_fixture(platform).id end)
    else
      Map.put_new_lazy(attrs, :channel_config_id, fn -> connector_fixture(platform).id end)
    end
  end

  def person_channel_fixture(attrs) do
    {:ok, channel} = attrs |> scoped_channel_attrs() |> People.add_channel()
    weight = attrs[:weight] || attrs["weight"] || channel.weight
    channel |> PersonChannel.weight_changeset(%{weight: weight}) |> Repo.update!()
  end
end
