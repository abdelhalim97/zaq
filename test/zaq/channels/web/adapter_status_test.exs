defmodule Zaq.Channels.Web.AdapterStatusTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.{Api, WebBridge}
  alias Zaq.Event

  defmodule Adapter do
    def ingress_status(config, timeout_ms: 2_000) do
      case config.id do
        1 ->
          {:ok, %{status: :ok, summary: "Ready", observations: config.settings}}

        2 ->
          {:ok, %{status: :error, reason: :not_listening, summary: "Not listening"}}

        3 ->
          raise "secret-adapter-failure"

        4 ->
          {:ok, %{invalid: "secret-adapter-failure"}}

        5 ->
          receive do
            :never -> :ok
          end

        6 ->
          throw(config.settings)
      end
    end
  end

  defmodule OtherAdapter do
    def ingress_status(_, _), do: {:ok, %{status: :pending, summary: "Other transport"}}
  end

  defmodule Config do
    def get(:zaq, :channels, _),
      do: %{
        test_web: %{bridge: WebBridge, adapter: Adapter},
        other_web: %{bridge: WebBridge, adapter: OtherAdapter}
      }
  end

  defmodule LegacyConfig do
    def get(:zaq, :channels, _), do: %{test_web: %{bridge: WebBridge, adapter: __MODULE__}}
  end

  defmodule Resolver do
    def bridge_for(_), do: WebBridge
  end

  test "existing Channels event forwards config to dynamically resolved adapter" do
    event =
      Event.new(%{provider: "test_web", config: config(1)}, :channels,
        opts: [config: Config, bridge_module: Resolver]
      )

    assert {:ok, %{status: :ok, observations: %{}}} =
             Api.handle_event(event, :channel_ingress_status, %{}).response

    assert {:ok, %{status: :pending, summary: "Other transport"}} =
             WebBridge.channel_ingress_status(%{config(1) | provider: "other_web"},
               config: Config
             )
  end

  test "bridge relays adapter observations without interpreting package policy" do
    observations = %{verification: :adapter_owned, desired: "new", installed: "old"}

    assert {:ok, %{status: :ok, observations: ^observations}} =
             WebBridge.channel_ingress_status(%{config(1) | settings: observations},
               config: Config
             )

    assert {:ok, %{status: :error, reason: :not_listening}} =
             WebBridge.channel_ingress_status(config(2), config: Config)
  end

  test "missing callbacks, exceptions and invalid envelopes produce safe unknown" do
    assert {:ok, %{status: :unknown, reason: :readiness_unsupported}} =
             WebBridge.channel_ingress_status(config(1), config: LegacyConfig)

    for id <- [3, 4] do
      assert {:ok, %{status: :unknown} = status} =
               WebBridge.channel_ingress_status(config(id), config: Config)

      refute inspect(status) =~ "secret-adapter-failure"
    end
  end

  test "total deadline bounds adapter execution; disabled configs never invoke it" do
    assert {:ok, %{status: :unknown, reason: :check_timeout}} =
             WebBridge.channel_ingress_status(config(5), config: Config)

    assert {:ok, %{status: :disabled}} =
             WebBridge.channel_ingress_status(%{config(3) | enabled: false}, config: Config)

    assert {:error, :invalid_request} = WebBridge.channel_ingress_status(%{config(3) | id: nil})
  end

  property "arbitrary thrown adapter details cannot escape into channel status" do
    check all(value <- term()) do
      assert {:ok, %{status: :unknown, reason: :check_failed} = status} =
               WebBridge.channel_ingress_status(%{config(6) | settings: value}, config: Config)

      assert Map.keys(status) |> Enum.sort() == [:reason, :status, :summary]
    end
  end

  defp config(id), do: %{id: id, provider: "test_web", enabled: true, settings: %{}}
end
