defmodule Zaq.Channels.Web.ResponseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Web.Response

  describe "new/1" do
    test "rejects non-map response attributes" do
      for attrs <- [nil, [], "response"] do
        assert {:error, {:invalid_field, :response}} = Response.new(attrs)
      end
    end

    test "rejects unsupported protocol versions without coercion" do
      for protocol_version <- [0, 3, "2"] do
        assert {:error, {:invalid_field, :protocol_version}} =
                 Response.new(%{
                   request_id: "request-1",
                   type: :status,
                   protocol_version: protocol_version
                 })
      end
    end

    test "rejects types outside the atom allowlist" do
      for type <- [:unsupported, "status", nil] do
        assert {:error, {:invalid_field, :type}} =
                 Response.new(%{request_id: "request-1", type: type})
      end
    end

    property "rejects generated unsupported string types" do
      check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 32)) do
        type = "unsupported_" <> suffix

        assert {:error, {:invalid_field, :type}} =
                 Response.new(%{request_id: "request-1", type: type})
      end
    end
  end
end
