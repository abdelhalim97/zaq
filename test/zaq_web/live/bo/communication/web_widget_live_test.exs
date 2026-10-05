defmodule ZaqWeb.Live.BO.Communication.WebWidgetLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mox
  import Zaq.AccountsFixtures

  alias Zaq.Channels.Supervisor, as: ChannelsSupervisor
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Repo

  defmodule Adapter do
    @behaviour Zaq.Channels.Web.WidgetAdapter

    @impl true
    def build(config, _hooks),
      do: {:ok, {%{id: :widget, start: {Agent, :start_link, [fn -> config.token end]}}, []}}

    @impl true
    def embed_script(id, base_url),
      do: {:ok, "<script src=\"#{base_url}/widget.js\" data-widget-id=\"#{id}\"></script>"}
  end

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)
    user = admin_fixture(%{must_change_password: false})
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "mounts the real form and allows disabled configuration before prerequisites", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    refute has_element?(view, "#widget-config-form")

    assert has_element?(
             view,
             "#widget-breadcrumb a[href='/bo/channels/retrieval']",
             "Communication"
           )

    refute has_element?(view, "[phx-click='refresh']")
    refute has_element?(view, "#widget-runtime-status")
    refute has_element?(view, "#widget-base-url-error")
    refute has_element?(view, "#widget-adapter-error")
    assert has_element?(view, ".hero-globe-alt")
    view |> element("#new-widget-config") |> render_click()
    assert has_element?(view, "#widget-config-form")
    assert has_element?(view, "#widget-config-modal #widget-config-form")

    assert has_element?(
             view,
             "#widget-config-modal #widget-base-url-error",
             "Global base URL is missing"
           )

    assert has_element?(
             view,
             "#widget-config-modal a[href='/bo/system-config']",
             "System Configuration"
           )

    assert has_element?(
             view,
             "#widget-config-modal #widget-adapter-error",
             "Web Widget adapter is not configured"
           )

    assert has_element?(view, "#widget-config-modal #generate-widget-key[disabled]")
    refute has_element?(view, "input[name='widget[display_name]']")
    assert has_element?(view, "#widget-enabled[disabled]")
    create(view, "Support")
    config = Repo.get_by!(ChannelConfig, name: "Support")
    refute config.enabled
    assert has_element?(view, "#widget-id[value='#{config.id}']")
    assert has_element?(view, "#generate-widget-key")
    assert has_element?(view, "#widget-script-#{config.id}[disabled]")
    view |> element("#close-widget-modal") |> render_click()
    refute has_element?(view, "#widget-base-url-error")
    refute has_element?(view, "#widget-adapter-error")
  end

  test "key is revealed once, dismissal and connector switching remove it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Support")
    view |> element("#generate-widget-key") |> render_click()
    assert has_element?(view, "#new-widget-key")
    assert has_element?(view, "#rotate-widget-key[data-confirm]")
    view |> element("#dismiss-widget-key") |> render_click()
    refute has_element?(view, "#new-widget-key")
    view |> element("#rotate-widget-key") |> render_click()
    assert has_element?(view, "#new-widget-key")
    view |> element("#close-widget-modal") |> render_click()
    refute has_element?(view, "#widget-config-form")
    refute has_element?(view, "#new-widget-key")
    config = Repo.get_by!(ChannelConfig, name: "Support")
    view |> element("#edit-widget-#{config.id}") |> render_click()
    refute has_element?(view, "#new-widget-key")
    view |> element("#new-widget-config") |> render_click()
    refute has_element?(view, "#new-widget-key")
  end

  test "configured base URL leaves only the missing adapter error in the modal", %{conn: conn} do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    refute has_element?(view, "#widget-prerequisite-errors")
    view |> element("#new-widget-config") |> render_click()
    refute has_element?(view, "#widget-base-url-error")
    assert has_element?(view, "#widget-adapter-error")
  end

  test "multiple configs and IncomingMessageRouting choices remain isolated", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "First")
    first = Repo.get_by!(ChannelConfig, name: "First")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Second", "__none__")
    second = Repo.get_by!(ChannelConfig, name: "Second")
    assert IncomingMessageRouting.get_rule(%{channel_config_id: second.id}).routing_mode == :none
    assert IncomingMessageRouting.get_rule(%{channel_config_id: first.id}) == nil

    view
    |> element("#edit-widget-#{first.id}")
    |> render_click()

    assert has_element?(view, "#widget-id[value='#{first.id}']")
    refute has_element?(view, "#new-widget-key")
  end

  test "invalid origin and forged configuration fields are rejected", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")

    view |> element("#new-widget-config") |> render_click()

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "name" => "Bad",
        "enabled" => "false",
        "allowed_domains" => "*"
      }
    })

    assert render(view) =~ "invalid widget settings"
    assert ChannelConfig.list_by_provider("web_widget") == []
    view |> render_submit("save", %{"widget" => %{"name" => "Forged", "token" => "chosen"}})
    assert render(view) =~ "Invalid configuration request"
    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "stale edits offer contextual reload instead of a permanent refresh", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Original")
    config = Repo.get_by!(ChannelConfig, name: "Original")
    config |> Ecto.Changeset.change(name: "Changed elsewhere") |> Repo.update!()

    view
    |> element("#widget-config-form")
    |> render_submit(%{"widget" => %{"name" => "Stale edit"}})

    assert has_element?(view, "#widget-recovery-error", "changed elsewhere")
    view |> element("#reload-widget-config") |> render_click()
    assert has_element?(view, "input[name='widget[name]'][value='Changed elsewhere']")
    refute has_element?(view, "#reload-widget-config")
  end

  test "adapter snippet is escaped and live rotation refreshes the server-only key", %{conn: conn} do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous, :web_widget, %{bridge: WebBridge, runtime_builder: Adapter})
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    {:ok, missing_base_view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    missing_base_view |> element("#new-widget-config") |> render_click()
    assert has_element?(missing_base_view, "#widget-base-url-error")
    refute has_element?(missing_base_view, "#widget-adapter-error")
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Live widget")
    refute has_element?(view, "#widget-base-url-error")
    refute has_element?(view, "#widget-adapter-error")
    refute has_element?(view, "#widget-prerequisite-errors")
    config = Repo.get_by!(ChannelConfig, name: "Live widget")
    refute config.enabled
    on_exit(fn -> WebBridge.stop_runtime(%{id: config.id, provider: "web_widget"}) end)

    view |> element("#new-widget-config") |> render_click()
    create(view, "Second widget")
    second = Repo.get_by!(ChannelConfig, name: "Second widget")
    view |> element("#close-widget-modal") |> render_click()
    refute has_element?(view, "#widget-install-script")
    view |> element("#widget-script-#{config.id}") |> render_click()
    assert has_element?(view, "#widget-install-script", "<script")
    refute has_element?(view, "script[src='https://zaq.example.test/widget.js']")
    assert render(view) =~ "&lt;script"
    assert has_element?(view, "#widget-install-script", "data-widget-id=\"#{config.id}\"")
    view |> element("#widget-script-#{second.id}") |> render_click()
    refute has_element?(view, "#widget-installation-#{config.id}")

    assert has_element?(
             view,
             "#widget-installation-#{second.id} #widget-install-script",
             "data-widget-id=\"#{second.id}\""
           )

    view |> element("#widget-script-#{config.id}") |> render_click()
    view |> element("#widget-script-#{config.id}") |> render_click()
    refute has_element?(view, "#widget-install-script")
    view |> element("#edit-widget-#{config.id}") |> render_click()
    view |> element("#generate-widget-key") |> render_click()

    view |> element("#widget-config-form") |> render_submit(%{"widget" => %{"enabled" => "true"}})

    assert {:ok, %{state_pid: initial}} =
             ChannelsSupervisor.lookup_runtime("web_widget_#{config.id}")

    assert Agent.get(initial, & &1) == Repo.get!(ChannelConfig, config.id).token
    old_key = Agent.get(initial, & &1)
    view |> element("#rotate-widget-key") |> render_click()

    assert {:ok, %{state_pid: replacement}} =
             ChannelsSupervisor.lookup_runtime("web_widget_#{config.id}")

    refute initial == replacement
    refute Process.alive?(initial)
    refute Agent.get(replacement, & &1) == old_key
    assert Agent.get(replacement, & &1) == Repo.get!(ChannelConfig, config.id).token

    view
    |> element("#widget-config-form")
    |> render_submit(%{"widget" => %{"enabled" => "false"}})

    refute Process.alive?(replacement)
    refute Repo.get!(ChannelConfig, config.id).enabled
    refute has_element?(view, "#widget-runtime-status")
    view |> element("#widget-config-form") |> render_submit(%{"widget" => %{"enabled" => "true"}})

    assert {:ok, %{state_pid: reenabled}} =
             ChannelsSupervisor.lookup_runtime("web_widget_#{config.id}")

    view |> element("#archive-widget-config") |> render_click()
    assert Repo.get!(ChannelConfig, config.id).archived_at
    refute Process.alive?(reenabled)
    refute has_element?(view, "#new-widget-key")
  end

  defp create(view, name, agent_id \\ "") do
    unless has_element?(view, "#widget-config-form"),
      do: view |> element("#new-widget-config") |> render_click()

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "name" => name,
        "allowed_domains" => "https://parent.example.test",
        "enabled" => "false",
        "agent_id" => agent_id
      }
    })
  end
end
