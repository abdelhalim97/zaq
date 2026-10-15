defmodule Zaq.Channels.WebBridgeAdapterFailuresTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.BridgeSupervisor
  alias Zaq.Channels.Web.{Command, Context, Message}
  alias Zaq.Channels.WebBridge

  defmodule ErrorAdapter do
    def infrastructure_child_specs(_), do: {:error, :adapter_unavailable}
    def build_runtime_specs(_, _), do: :malformed
    def ingress_status(_, _), do: {:error, :check_timeout}
    def installation(_, _, _), do: throw(:private)
  end

  defmodule RaiseAdapter do
    def build_runtime_specs(_, _), do: raise("private")
  end

  defmodule ThrowAdapter do
    def build_runtime_specs(_, _), do: throw(:private)
  end

  defmodule MalformedInfrastructureAdapter do
    def infrastructure_child_specs(_), do: :malformed
  end

  defmodule ThrowInfrastructureAdapter do
    def infrastructure_child_specs(_), do: throw(:private)
  end

  defmodule OptionsAdapter do
    def infrastructure_child_specs(opts), do: {:ok, [opts]}
  end

  defmodule ChildAdapter do
    def infrastructure_child_specs(_), do: {:ok, [Agent.child_spec(fn -> :ready end)]}
  end

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      test_error: %{adapter: ErrorAdapter},
      test_invalid: %{adapter: ErrorAdapter},
      test_raise: %{adapter: RaiseAdapter},
      test_throw: %{adapter: ThrowAdapter},
      test_malformed_infrastructure: %{adapter: MalformedInfrastructureAdapter},
      test_throw_infrastructure: %{adapter: ThrowInfrastructureAdapter},
      web_widget: %{adapter: OptionsAdapter},
      test_child: %{adapter: ChildAdapter},
      test_unloaded: %{adapter: Zaq.Channels.WebBridgeAdapterFailuresTest.UnloadedAdapter}
    })

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:zaq, :channels),
        else: Application.put_env(:zaq, :channels, previous)
    end)

    :ok
  end

  test "rejects malformed connector and runtime responses and hides callback failures" do
    assert {:error, :invalid_connector} = WebBridge.build_runtime_specs(%{})

    assert {:error, :invalid_runtime_specs} =
             WebBridge.build_runtime_specs(%{id: 1, provider: :test_invalid})

    assert {:error, :runtime_construction_failed} =
             WebBridge.build_runtime_specs(%{id: 1, provider: :test_raise})

    assert {:error, :runtime_construction_failed} =
             WebBridge.build_runtime_specs(%{id: 1, provider: :test_throw})
  end

  test "normalizes unavailable infrastructure and installation failures" do
    assert {:error, :provider_infrastructure_start_failed} =
             WebBridge.build_runtime_specs({:provider, :test_error}, [])

    config = %{id: 2, provider: :test_error}

    assert {:error, :installation_failed} =
             WebBridge.installation(
               %{op: :installation, config: config, base_url: "https://x"},
               []
             )

    assert {:error, :provider_infrastructure_start_failed} =
             WebBridge.build_runtime_specs({:provider, :test_malformed_infrastructure}, [])

    assert {:error, :provider_infrastructure_start_failed} =
             WebBridge.build_runtime_specs({:provider, :test_throw_infrastructure}, [])
  end

  test "returns bounded readiness result for an adapter timeout" do
    assert {:ok,
            %{
              status: :unknown,
              reason: :check_timeout,
              summary: "Transport readiness cannot be verified"
            }} =
             WebBridge.channel_ingress_status(%{id: 3, provider: :test_error})
  end

  test "widget development mode preserves secure session options" do
    previous = System.get_env("WIDGET_DEV_MODE")
    System.put_env("WIDGET_DEV_MODE", "true")

    try do
      assert {:ok, {nil, [opts]}} =
               WebBridge.build_runtime_specs({:provider, :web_widget},
                 host_options: [session: [secure: true]]
               )

      assert opts[:session][:secure] == true
      assert opts[:session][:partitioned] == false
    after
      if is_nil(previous),
        do: System.delete_env("WIDGET_DEV_MODE"),
        else: System.put_env("WIDGET_DEV_MODE", previous)
    end
  end

  test "rejects mismatched adapter payloads and malformed invocation" do
    assert {:ok, context} =
             Context.new(%{user_id: 1}, consumer: :widget, channel_config_id: 8, sender_id: "s")

    {:ok, command} = Command.new(%{request_id: "r", type: :conversation_init})

    {:ok, message} =
      Message.new(%{
        request_id: "r",
        message_id: "m",
        content: "x",
        channel: "w",
        mode: :async,
        timestamp: DateTime.utc_now()
      })

    assert {:error, :invalid_payload} = WebBridge.from_adapter(%{id: 8}, :bad, context: context)
    assert {:error, :unauthorized} = WebBridge.from_adapter(%{id: 9}, command, context: context)
    assert {:error, :unauthorized} = WebBridge.from_adapter(:bad, message, [])
  end

  test "accepts ignored non-map runtime and web provider runtime" do
    assert :ok = WebBridge.start_runtime(:bad)
    assert :ok = WebBridge.start_runtime(%{provider: :web})

    assert {:error, :provider_infrastructure_start_failed} =
             WebBridge.build_runtime_specs({:provider, :test_unloaded}, [])
  end

  test "provider startup starts registered infrastructure and cleanup stops it" do
    target = {:provider, :test_child}
    bridge_id = WebBridge.runtime_bridge_id(target)
    on_exit(fn -> BridgeSupervisor.stop_bridge_runtime(target, bridge_id) end)
    assert :ok = WebBridge.start_runtime(target)

    assert {:ok, %{listener_pids: [pid]}} =
             BridgeSupervisor.lookup_runtime(bridge_id)

    assert Process.alive?(pid)
  end
end
