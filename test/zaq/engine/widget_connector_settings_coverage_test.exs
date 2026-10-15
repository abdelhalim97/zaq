defmodule Zaq.Engine.WidgetConnectorSettingsCoverageTest do
  use Zaq.DataCase, async: true

  import Mox

  alias Zaq.Engine.{ChannelConfig, WidgetConnectorSettings}
  alias Zaq.Event
  alias Zaq.NodeRouterMock, as: Router

  setup :verify_on_exit!

  test "default entry point rejects unsupported requests" do
    assert {:error, :invalid_request} = WidgetConnectorSettings.execute(%{op: :unsupported})
  end

  test "embed script requires a global base URL without dispatching" do
    assert :ok = Zaq.System.set_global_base_url(nil)

    assert {:error, :missing_global_base_url} =
             WidgetConnectorSettings.execute(%{op: :embed_script, id: :new}, node_router: Router)
  end

  test "embed script propagates a missing connector" do
    assert {:error, :connector_not_found} =
             WidgetConnectorSettings.execute(%{op: :embed_script, id: 9_999_999},
               node_router: Router
             )
  end

  test "key mutation rejects a missing connector" do
    assert {:error, :connector_not_found} =
             WidgetConnectorSettings.execute(
               %{op: :rotate_key, id: 9_999_999, revision: "revision"},
               node_router: Router
             )
  end

  test "key mutation requires a revision and leaves the connector unchanged" do
    expect_successful_save_sequence(2)
    {:ok, created} = save(%{"name" => "Support", "enabled" => false})
    assert created.runtime == :synced
    selected = created.snapshot.selected
    before = Repo.get!(ChannelConfig, selected.id)

    assert {:error, :invalid_request} =
             WidgetConnectorSettings.execute(%{op: :rotate_key, id: selected.id},
               node_router: Router
             )

    after_config = Repo.get!(ChannelConfig, selected.id)
    assert after_config.token == before.token
    assert after_config.settings == before.settings

    expect(Router, :dispatch, 1, fn %Event{opts: opts} = event ->
      assert opts[:action] == :channel_capability_snapshot
      %{event | response: {:ok, %{resolved: %{runtime: true, installation: true}}}}
    end)

    assert {:ok, snapshot} =
             WidgetConnectorSettings.execute(%{op: :snapshot, id: selected.id},
               node_router: Router
             )

    assert snapshot.selected.revision == selected.revision
    assert snapshot.adapter == {:ok, %{available?: true}}
  end

  test "clearing display name removes stored setting and projects empty value" do
    expect_successful_save_sequence(4)
    {:ok, created} = save(%{"name" => "Support", "enabled" => false, "display_name" => "Support"})
    assert created.runtime == :synced
    selected = created.snapshot.selected

    assert {:ok, cleared} =
             WidgetConnectorSettings.execute(
               %{
                 op: :save,
                 id: selected.id,
                 revision: selected.revision,
                 params: %{"display_name" => ""}
               },
               node_router: Router
             )

    assert cleared.runtime == :synced
    settings = Repo.get!(ChannelConfig, selected.id).settings
    refute Map.has_key?(settings, "display_name")
    assert cleared.snapshot.selected.display_name == ""
    assert settings["identity_issuer"] == "zaq_issuer"
  end

  test "successful runtime sync persists the selected connector" do
    expect(Router, :dispatch, 2, fn %Event{opts: opts} = event ->
      response =
        case opts[:action] do
          :sync_channel_runtime -> {:ok, %{synced: true}}
          :channel_capability_snapshot -> {:ok, %{resolved: %{runtime: true, installation: true}}}
        end

      %{event | response: response}
    end)

    assert {:ok, result} = save(%{"name" => "Synced", "enabled" => false})
    assert result.runtime == :synced
    assert Repo.get!(ChannelConfig, result.snapshot.selected.id).name == "Synced"
  end

  for {label, failure} <- [
        {"returns a non-event", :non_event},
        {"raises", :raise},
        {"throws", :throw}
      ] do
    test "runtime sync #{label} becomes a safe pending result" do
      expect(Router, :dispatch, 2, fn %Event{opts: opts} = event ->
        case opts[:action] do
          :sync_channel_runtime ->
            assert opts[:confidential]

            case unquote(failure) do
              :non_event -> :unexpected_response
              :raise -> raise "private sync failure"
              :throw -> throw(:private_sync_failure)
            end

          :channel_capability_snapshot ->
            %{event | response: {:ok, %{resolved: %{runtime: true, installation: true}}}}
        end
      end)

      assert {:ok, result} = save(%{"name" => "Pending", "enabled" => false})
      assert result.runtime == {:pending, :runtime_sync_failed}
      refute inspect(result) =~ "private"
      assert Repo.get!(ChannelConfig, result.snapshot.selected.id).name == "Pending"
    end
  end

  defp save(params) do
    WidgetConnectorSettings.execute(%{op: :save, id: :new, params: params}, node_router: Router)
  end

  defp expect_successful_save_sequence(count) do
    expect(Router, :dispatch, count, fn %Event{opts: opts} = event ->
      case opts[:action] do
        :sync_channel_runtime ->
          assert opts[:confidential]
          %{event | response: {:ok, %{synced: true}}}

        :channel_capability_snapshot ->
          %{event | response: {:ok, %{resolved: %{runtime: true, installation: true}}}}
      end
    end)
  end
end
