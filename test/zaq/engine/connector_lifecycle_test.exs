defmodule Zaq.Engine.ConnectorLifecycleTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ConnectorLifecycle
  alias Zaq.Event

  defmodule Router do
    def dispatch(%Event{opts: opts} = event) do
      send(self(), {:channels_call, opts[:action], event.request})

      response =
        case opts[:action] do
          :connector_teardown_ingress -> {:ok, :not_required}
          :connector_sync_runtime -> :ok
        end

      %{event | response: response}
    end
  end

  defmodule DataSourcesStub do
    def stop_config_watch_channels(id) do
      send(self(), {:stop_watches, id})
      Process.get(:stop_response, {:ok, 2})
    end

    def reconcile_archived_config_watches(id) do
      send(self(), {:reconcile_watches, id})
      Process.get(:reconcile_response, {:ok, 1})
    end
  end

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "archive-watch",
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: %{"volumes" => [%{"name" => "v", "path" => "archive-test"}]}
      })
      |> Repo.insert!()

    Process.put(:config_id, config.id)
    %{config: config}
  end

  test "data-source archive orders watch stop, Channels archive and reconciliation" do
    assert {:ok, result} = archive()

    id = Process.get(:config_id)
    assert result.channel_config_id == id
    assert result.watch_teardown == %{status: :stopped, count: 2}
    assert result.cleanup == %{status: :scheduled, count: 1}

    assert_received {:stop_watches, ^id}
    assert_received {:channels_call, :connector_teardown_ingress, %{config: %{id: ^id}}}

    assert_received {:channels_call, :connector_sync_runtime,
                     %{after_config: %{id: ^id, enabled: false}}}

    assert_received {:reconcile_watches, ^id}
  end

  test "partial watch teardown stops before Channels archive" do
    Process.put(:stop_response, {:error, [{7, :provider_down}]})

    assert {:error, {:watch_teardown_failed, [{7, :provider_down}]}} = archive()
    refute_received {:channels_call, :connector_teardown_ingress, _}
    refute_received {:channels_call, :connector_sync_runtime, _}
    refute_received {:reconcile_watches, _}
  end

  test "post-archive cleanup failures are truthful pending warnings" do
    Process.put(:reconcile_response, {:error, :queue_down})

    assert {:ok, %{status: :archived, cleanup: %{status: :pending, reason: :queue_down}}} =
             archive()
  end

  test "communication connectors skip Engine watch operations" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    config |> Ecto.Changeset.change(kind: "retrieval") |> Repo.update!()

    assert {:ok, %{watch_teardown: %{status: :not_required}, cleanup: %{status: :not_required}}} =
             archive()

    refute_received {:stop_watches, _}
    refute_received {:reconcile_watches, _}
  end

  defp archive do
    ConnectorLifecycle.archive(
      %{
        channel_config_id: Process.get(:config_id),
        provider: "disk",
        kind: Repo.get!(ChannelConfig, Process.get(:config_id)).kind
      },
      %{user_id: 1},
      router: Router,
      data_sources_module: DataSourcesStub
    )
  end
end
