defmodule Zaq.Channels.Web.DeliveryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Web.Delivery

  defp valid_attrs do
    %{consumer: :bo, topic: "chat:session", events: %{status: :status_update}}
  end

  defp valid_reference do
    "chat:session"
    |> Delivery.bo()
    |> Delivery.reference()
  end

  test "new rejects non-map delivery attributes" do
    assert {:error, {:invalid_field, :delivery}} = Delivery.new(nil)
    assert {:error, {:invalid_field, :delivery}} = Delivery.new([])
  end

  test "new requires an atom consumer" do
    assert {:error, {:invalid_field, :consumer}} =
             Delivery.new(%{valid_attrs() | consumer: "bo"})

    assert {:error, {:invalid_field, :consumer}} =
             Delivery.new(%{valid_attrs() | consumer: nil})
  end

  test "new defaults nil events to an empty mapping" do
    assert {:ok, %Delivery{consumer: :bo, topic: "chat:session", events: %{}}} =
             Delivery.new(%{valid_attrs() | events: nil})
  end

  test "new rejects invalid event maps and unsupported wire-name types" do
    assert {:error, {:invalid_field, :events}} = Delivery.new(%{valid_attrs() | events: []})

    assert {:error, {:invalid_field, :events}} =
             Delivery.new(%{valid_attrs() | events: %{status: 0}})
  end

  test "new requires a positive channel config id" do
    assert {:error, {:invalid_field, :channel_config_id}} =
             Delivery.new(Map.put(valid_attrs(), :channel_config_id, 0))

    assert {:error, {:invalid_field, :channel_config_id}} =
             Delivery.new(Map.put(valid_attrs(), :channel_config_id, -1))
  end

  test "from_reference rejects non-map references" do
    assert {:error, :invalid_delivery_descriptor} = Delivery.from_reference(nil)
    assert {:error, :invalid_delivery_descriptor} = Delivery.from_reference([])
  end

  test "from_reference requires an events map" do
    assert {:error, :invalid_delivery_descriptor} =
             valid_reference() |> Map.delete("events") |> Delivery.from_reference()
  end

  test "from_reference rejects unknown and non-string semantic event keys" do
    assert {:error, :invalid_delivery_descriptor} =
             valid_reference()
             |> Map.put("events", %{"execute_mfa" => "run"})
             |> Delivery.from_reference()

    assert {:error, :invalid_delivery_descriptor} =
             valid_reference()
             |> Map.put("events", %{:status => "status_update"})
             |> Delivery.from_reference()
  end

  property "from_reference rejects every generated unknown semantic event key" do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      reference = Map.put(valid_reference(), "events", %{("not_a_semantic_" <> suffix) => "run"})
      assert {:error, :invalid_delivery_descriptor} = Delivery.from_reference(reference)
    end
  end
end
