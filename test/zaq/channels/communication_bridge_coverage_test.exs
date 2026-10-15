defmodule Zaq.Channels.CommunicationBridgeCoverageTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  defmodule EmptyConfig do
    def get(:zaq, :channels, _default), do: %{}
  end

  defmodule ErrorRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:dispatched, event})
      %{event | response: {:error, :capture_denied}}
    end
  end

  defmodule InvalidReceiveRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:dispatched, event})
      :router_unavailable
    end
  end

  defmodule InvalidRouteRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:dispatched, event})
      :router_unavailable
    end
  end

  test "materialization reports missing bridge before database access" do
    assert {:error, {:no_bridge, :mattermost}} =
             CommunicationBridge.materialize_record(
               %{provider: :mattermost, reference: "media-1"},
               materialization_verified: true,
               config: EmptyConfig
             )
  end

  test "materialization rejects requests without a valid provider" do
    for request <- [%{}, %{provider: nil}, %{provider: 42}] do
      assert {:error, {:invalid_materialization_request, :missing_provider}} =
               CommunicationBridge.materialize_record(request, materialization_verified: true)
    end
  end

  test "provider runtime rejects unsupported target shapes" do
    for target <- [42, {:invalid, :mattermost}, []] do
      assert {:error, :invalid_runtime_config} =
               CommunicationBridge.sync_provider_runtime(target)
    end
  end

  test "one-argument ingress deletion reports an unavailable bridge" do
    provider = "unregistered-#{System.unique_integer([:positive])}"

    assert {:error, {:no_bridge, ^provider}} =
             CommunicationBridge.delete_ingress_subscription(provider)
  end

  test "receive message propagates Engine errors from the router" do
    incoming = incoming()

    assert {:error, :capture_denied} =
             CommunicationBridge.receive_message(incoming, node_router: ErrorRouter)

    assert_receive {:dispatched,
                    %Event{
                      next_hop: %{destination: :engine},
                      opts: opts,
                      request: %Incoming{channel_id: "channel-1", provider: :mattermost}
                    }}

    assert Keyword.fetch!(opts, :action) == :receive_incoming_message
  end

  test "receive message rejects non-event router responses" do
    incoming = incoming()

    assert {:error, :incoming_message_failed} =
             CommunicationBridge.receive_message(incoming, node_router: InvalidReceiveRouter)

    assert_receive {:dispatched,
                    %Event{
                      next_hop: %{destination: :engine},
                      opts: opts,
                      request: %Incoming{channel_id: "channel-1", provider: :mattermost}
                    }}

    assert Keyword.fetch!(opts, :action) == :receive_incoming_message
  end

  test "incoming routing rejects non-event router responses" do
    incoming = incoming()
    actor = %{id: "actor-1"}

    assert {:error, {:unexpected_response, :router_unavailable}} =
             CommunicationBridge.route_incoming_message(incoming, [], actor,
               node_router: InvalidRouteRouter
             )

    assert_receive {:dispatched,
                    %Event{
                      next_hop: %{destination: :engine},
                      opts: opts,
                      request: %Incoming{channel_id: "channel-1", provider: :mattermost},
                      actor: ^actor
                    }}

    assert Keyword.fetch!(opts, :action) == :route_incoming_message
  end

  defp incoming do
    %Incoming{content: "hello", channel_id: "channel-1", provider: :mattermost}
  end
end
