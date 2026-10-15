defmodule Zaq.Channels.Web.ValidationTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.{Command, Message, Response, Validation}

  describe "map/2" do
    test "rejects non-map values and identifies the requested field" do
      assert Validation.map(["not", "a", "map"], :params) ==
               {:error, {:invalid_field, :params}}

      assert Validation.map(42, :payload) == {:error, {:invalid_field, :payload}}
    end
  end

  describe "list/2" do
    test "rejects non-list values and identifies the requested field" do
      assert Validation.list(%{file: "a.txt"}, :attachments) ==
               {:error, {:invalid_field, :attachments}}

      assert Validation.list("not a list", :attachments) ==
               {:error, {:invalid_field, :attachments}}
    end
  end

  test "Command propagates an invalid params type" do
    assert Command.new(%{request_id: "request-1", type: :conversation_history, params: []}) ==
             {:error, {:invalid_field, :params}}
  end

  test "Response propagates an invalid payload type" do
    assert Response.new(%{request_id: "request-1", type: :status, payload: []}) ==
             {:error, {:invalid_field, :payload}}
  end

  test "Message propagates an invalid attachments type" do
    assert Message.new(%{
             request_id: "request-1",
             message_id: "message-1",
             content: "hello",
             timestamp: DateTime.utc_now(),
             channel: "web",
             mode: :sync,
             attachments: %{}
           }) == {:error, {:invalid_field, :attachments}}
  end
end
