defmodule ZaqWeb.Live.BO.Communication.AgentRoutingOptionsTest do
  use ExUnit.Case, async: true
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions

  @invalid_selection {:error, :invalid_routing_selection}

  test "rejects a top-level list instead of a map of rules" do
    assert AgentRoutingOptions.form_rules([%{"choice" => "1"}]) == @invalid_selection
  end

  test "rejects every nonpositive or malformed scope ID" do
    for scope_key <- ["person_id", "channel_config_id", "retrieval_channel_id"],
        invalid_id <- ["0", "-1", "12x"] do
      rule = Map.put(%{"choice" => ""}, scope_key, invalid_id)

      assert AgentRoutingOptions.form_rules(%{"one" => rule}) == @invalid_selection,
             "expected #{inspect(scope_key)}=#{inspect(invalid_id)} to be rejected"
    end
  end

  test "rejects the whole selection when a later rule has an invalid scope ID" do
    input = %{
      "one" => %{"person_id" => "12", "choice" => ""},
      "two" => %{"channel_config_id" => "0", "choice" => ""}
    }

    assert AgentRoutingOptions.form_rules(input) == @invalid_selection
  end

  test "rejects a non-string topic ID" do
    input = %{"one" => %{"topic_id" => 42, "choice" => ""}}

    assert AgentRoutingOptions.form_rules(input) == @invalid_selection
  end
end
