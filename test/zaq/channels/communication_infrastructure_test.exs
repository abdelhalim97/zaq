defmodule Zaq.Channels.CommunicationInfrastructureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Bridge, as: ChannelBridge
  alias Zaq.Channels.CommunicationBridge

  defmodule Bridge do
    def sync_provider_runtime({:provider, provider}, opts) do
      send(opts[:owner], {:bridge_options, provider, opts})
      :ok
    end

    def sync_provider_runtime(config, opts) when is_map(config) do
      send(opts[:owner], {:connector_options, config, opts})
      :ok
    end
  end

  defmodule LegacyBridge do
    use Zaq.Channels.Bridge

    def build_runtime_specs(_), do: {:error, :unsupported}

    def sync_provider_runtime(config) do
      send(config.owner, {:legacy_connector, config})
      :ok
    end
  end

  defmodule RuntimeSupervisor do
    def start_runtime(id, state, listeners) do
      send(self(), {:runtime_start, id, state, listeners})

      if Keyword.get(List.first(listeners) || [], :already_running),
        do: {:error, :already_running},
        else: {:ok, self()}
    end

    def stop_bridge_runtime(target, id) do
      send(self(), {:runtime_stop, target, id})
      :ok
    end
  end

  defmodule SpecBridge do
    use Zaq.Channels.Bridge

    def runtime_supervisor_module, do: RuntimeSupervisor
    def build_runtime_specs(config), do: {:ok, {%{connector: config}, []}}

    def build_runtime_specs({:provider, _} = target, opts) do
      send(self(), {:runtime_specs, target, opts})
      {:ok, {nil, [opts]}}
    end

    def build_runtime_specs(config, opts), do: super(config, opts)
  end

  defmodule StartOnlyBridge do
    def start_runtime(target, opts) do
      send(self(), {:start_only, target, opts})
      :ok
    end
  end

  defmodule Adapter do
    def infrastructure_child_specs(_), do: raise("routing must stop at the bridge")
  end

  defmodule Config do
    def get(:zaq, :channels, _),
      do: %{
        first: %{bridge: Bridge, adapter: Adapter},
        second: %{bridge: Bridge, adapter: Adapter},
        legacy: %{bridge: LegacyBridge},
        absent: %{bridge: __MODULE__, adapter: Adapter}
      }
  end

  defmodule FailingBridge do
    def sync_provider_runtime({:provider, _}, opts), do: Keyword.fetch!(opts, :failure).()
  end

  defmodule FailingConfig do
    def get(:zaq, :channels, _), do: %{failing: %{bridge: FailingBridge}}
  end

  test "routes each provider to its bridge with untouched initialization options" do
    opts = [
      config: Config,
      owner: self(),
      host_options: [shared: make_ref()],
      adapter_options: %{first: [shared: :override]}
    ]

    assert :ok = CommunicationBridge.sync_provider_runtime({:provider, :first}, opts)
    assert :ok = CommunicationBridge.sync_provider_runtime({:provider, :second}, opts)
    assert_receive {:bridge_options, :first, ^opts}
    assert_receive {:bridge_options, :second, ^opts}
    refute_receive {:bridge_options, :absent, _}
  end

  test "missing bridge infrastructure capability is a no-op" do
    assert :ok =
             CommunicationBridge.sync_provider_runtime({:provider, :absent}, config: __MODULE__)
  end

  test "adding options does not change a connector target into shared provider startup" do
    config = %{id: 1, provider: "first", enabled: true}
    opts = [config: Config, owner: self(), host_options: [opaque: make_ref()]]
    assert :ok = CommunicationBridge.sync_provider_runtime(config, opts)
    assert_receive {:connector_options, ^config, ^opts}
    refute_receive {:bridge_options, _, _}
  end

  test "option-aware dispatch preserves legacy connector overrides" do
    config = %{id: 2, provider: "legacy", enabled: true, owner: self()}
    assert :ok = CommunicationBridge.sync_provider_runtime(config, config: Config)
    assert_receive {:legacy_connector, ^config}
    assert :ok = ChannelBridge.dispatch_provider_runtime_sync(LegacyBridge, config)
    assert_receive {:legacy_connector, ^config}
  end

  test "Bridge defaults construct both runtime targets through the common supervisor API" do
    opts = [opaque: make_ref()]
    target = {:provider, :first}
    assert :ok = SpecBridge.sync_provider_runtime(target, opts)
    assert_receive {:runtime_specs, ^target, ^opts}
    assert_receive {:runtime_start, "provider:first", nil, [^opts]}
    assert :ok = SpecBridge.sync_provider_runtime(target)
    assert_receive {:runtime_specs, ^target, []}
    assert_receive {:runtime_start, "provider:first", nil, [[]]}

    config = %{id: 1, provider: "first", enabled: true}
    assert :ok = SpecBridge.sync_provider_runtime(config, opts)
    assert_receive {:runtime_start, "first_1", %{connector: ^config}, []}
  end

  test "repeated provider synchronization never restarts shared services" do
    target = {:provider, :first}
    assert :ok = SpecBridge.sync_provider_runtime(target, already_running: true)
    assert_receive {:runtime_start, "provider:first", nil, _}
    refute_receive {:runtime_stop, _, _}
  end

  test "legacy macro bridges without provider specs do not start empty shared runtimes" do
    assert :ok = LegacyBridge.sync_provider_runtime({:provider, :legacy}, [])
    refute_receive {:legacy_connector, _}
    refute_receive {:runtime_start, _, _, _}
  end

  test "generic lifecycle contracts belong to Bridge, not CommunicationBridge" do
    optional = ChannelBridge.behaviour_info(:optional_callbacks)

    for callback <- [start_runtime: 2, sync_provider_runtime: 2, build_runtime_specs: 2] do
      assert callback in optional
    end

    refute {:start_runtime, 2} in CommunicationBridge.behaviour_info(:callbacks)
  end

  test "provider fallback invokes the optional Bridge start callback when sync is absent" do
    target = {:provider, :first}
    opts = [opaque: make_ref()]
    assert :ok = ChannelBridge.dispatch_provider_runtime_sync(StartOnlyBridge, target, opts)
    assert_receive {:start_only, ^target, ^opts}
  end

  property "domain routing treats initialization values as opaque" do
    check all(value <- term()) do
      opts = [config: Config, owner: self(), host_options: value, adapter_options: value]
      assert :ok = CommunicationBridge.sync_provider_runtime({:provider, :first}, opts)
      assert :ok = CommunicationBridge.sync_provider_runtime({:provider, :second}, opts)
      assert_receive {:bridge_options, :first, ^opts}
      assert_receive {:bridge_options, :second, ^opts}
    end
  end

  def get(:zaq, :channels, _), do: %{absent: %{bridge: __MODULE__, adapter: Adapter}}

  test "bridge failures and invalid results never expose private configuration" do
    for failure <- [
          fn -> raise "private configuration" end,
          fn -> throw(%{private: :configuration}) end,
          fn -> {:error, %{private: :configuration}} end,
          fn -> {:ok, :invalid_specs} end
        ] do
      assert {:error, :provider_infrastructure_start_failed} =
               CommunicationBridge.sync_provider_runtime({:provider, :failing},
                 config: FailingConfig,
                 failure: failure
               )
    end
  end
end
