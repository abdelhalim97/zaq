defmodule Zaq.Channels.Web.CommandTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.Command

  test "rejects non-map command input" do
    assert Command.new(nil) == {:error, {:invalid_field, :command}}

    assert Command.new(request_id: "r1", type: :conversation_init) ==
             {:error, {:invalid_field, :command}}
  end
end
