defmodule Zaq.Channels.Web.ContextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Web.{Context, Delivery}

  defp actor, do: %{user_id: 1}

  defp bo_opts(opts \\ []) do
    Keyword.merge([consumer: :bo, delivery: Delivery.bo("chat:session")], opts)
  end

  test "rejects invalid arguments to new" do
    assert Context.new(:not_a_map, bo_opts()) == {:error, :unauthorized}
    assert Context.new(actor(), :not_a_keyword_list) == {:error, :unauthorized}
  end

  test "validate rejects values without a valid Context capability set" do
    assert Context.validate(nil) == {:error, :invalid_web_context}
    assert Context.validate(%{}) == {:error, :invalid_web_context}

    malformed = %Context{consumer: :bo, capabilities: []}
    assert Context.validate(malformed) == {:error, :invalid_web_context}
  end

  test "rejects invalid channel config ids" do
    for id <- [0, -1, "7"] do
      assert Context.new(actor(), bo_opts(channel_config_id: id)) ==
               {:error, {:invalid_field, :channel_config_id}}
    end
  end

  property "non-positive channel config ids are rejected" do
    check all(id <- integer(-100..0)) do
      assert Context.new(actor(), bo_opts(channel_config_id: id)) ==
               {:error, {:invalid_field, :channel_config_id}}
    end
  end

  test "rejects missing or unsupported consumers" do
    assert Context.new(actor(), delivery: Delivery.bo("chat:session")) ==
             {:error, {:invalid_field, :consumer}}

    assert Context.new(actor(), bo_opts(consumer: :other)) ==
             {:error, {:invalid_field, :consumer}}
  end

  test "capabilities must be supplied as an allowed list" do
    for capabilities <- [nil, MapSet.new()] do
      assert Context.new(actor(), bo_opts(capabilities: capabilities)) ==
               {:error, {:invalid_field, :capabilities}}
    end
  end

  test "revalidates delivery structs and their contents" do
    delivery = Delivery.bo("chat:session")
    malformed = %{delivery | topic: "  "}

    assert Context.new(actor(), bo_opts(delivery: malformed)) ==
             {:error, {:invalid_field, :delivery}}

    valid_context = %Context{
      consumer: :bo,
      actor: actor(),
      capabilities: MapSet.new(),
      delivery: malformed
    }

    assert Context.validate(valid_context) == {:error, {:invalid_field, :delivery}}
  end

  test "rejects delivery for a different consumer" do
    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        topic: "widget:session",
        protocol_version: 2,
        events: %{}
      })

    assert Context.new(actor(), bo_opts(delivery: delivery)) ==
             {:error, {:invalid_field, :delivery}}
  end

  test "rejects non-Delivery values" do
    for delivery <- [%{consumer: :bo}, "chat:session"] do
      assert Context.new(actor(), bo_opts(delivery: delivery)) ==
               {:error, {:invalid_field, :delivery}}
    end
  end

  test "content filter must be a valid list" do
    for content_filter <- [nil, "docs/"] do
      assert Context.new(actor(), bo_opts(content_filter: content_filter)) ==
               {:error, {:invalid_field, :content_filter}}
    end
  end
end
