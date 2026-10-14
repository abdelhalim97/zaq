defmodule ZaqWeb.Live.BO.System.ConnectorPeopleLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Accounts.People
  alias Zaq.Channels.AgentRouting
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions

  test "connector selection scopes routing, includes disabled entries and validates without queries",
       %{conn: conn} do
    Zaq.TimezoneTestHelpers.stub_system_timezone("Etc/UTC")
    user = admin_fixture()
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, person} = People.create_person(%{full_name: "Connector owner"})
    first = connector("Disabled origin", false)
    other = connector("Other origin", true)
    {:ok, view, _} = live(conn, ~p"/bo/people")
    render_click(view, "select_person", %{"id" => to_string(person.id)})

    render_click(view, "open_modal", %{
      "action" => "add",
      "entity" => "channel",
      "parent_id" => to_string(person.id)
    })

    pid = self()
    handler = "connector-validate-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ -> send(pid, {:validation_query, metadata.query, metadata.params}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    attrs = %{
      "platform" => "discord",
      "channel_config_id" => to_string(first.id),
      "channel_identifier" => "123"
    }

    render_change(view, "validate", %{"channel" => attrs})
    # BOLayout reads its existing update-badge flag on every render; channel
    # validation itself must not reload connectors, rules or other reference data.
    assert_received {:validation_query, _, ["ui.update_badge_enabled"]}
    refute_received {:validation_query, _, _}
    assert render(view) =~ "Disabled origin (disabled)"
    assert has_element?(view, "#person-provider-routing-select-#{first.id}")
    refute has_element?(view, "#person-provider-routing-select-#{other.id}")
    :telemetry.detach(handler)

    assert Enum.map(ChannelConfig.list_incoming_routing_configs_for_platform("discord"), & &1.id) ==
             [other.id]

    forged =
      Map.put(attrs, "rules", rule_input(other.id))

    render_submit(view, "save", %{"channel" => forged})
    assert People.list_person_channels(person.id) == []

    assert IncomingMessageRouting.get_rule(%{person_id: person.id, channel_config_id: other.id}) ==
             nil

    attrs =
      Map.put(attrs, "rules", rule_input(first.id))

    render_submit(view, "save", %{"channel" => attrs})
    assert [channel] = People.list_person_channels(person.id)
    assert channel.channel_config_id == first.id

    assert %{routing_mode: :none} =
             IncomingMessageRouting.get_rule(%{person_id: person.id, channel_config_id: first.id})

    {:ok, view, _} = live(conn, ~p"/bo/people")
    render_click(view, "select_person", %{"id" => to_string(person.id)})

    render_click(view, "open_modal", %{
      "action" => "edit",
      "entity" => "channel",
      "id" => to_string(channel.id),
      "parent_id" => to_string(person.id)
    })

    assert has_element?(
             view,
             "#person-provider-routing-select-#{first.id} input[data-select-value][value='#{AgentRouting.none_value()}']"
           )

    refute has_element?(view, "#person-provider-routing-select-#{other.id}")
  end

  defp rule_input(id) do
    %{
      AgentRoutingOptions.rule_key(%{channel_config_id: id}) => %{
        "channel_config_id" => to_string(id),
        "choice" => AgentRouting.none_value()
      }
    }
  end

  defp connector(name, enabled) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: name,
      provider: "discord",
      kind: "retrieval",
      enabled: enabled,
      url: "https://discord.example.com",
      token: "test-token"
    })
    |> Repo.insert!()
  end
end
