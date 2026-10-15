defmodule Zaq.Channels.Web.StylesheetTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.{Command, Stylesheet}

  test "accepts an omitted stylesheet URL and preserves explicit nil in init params" do
    assert :ok = Stylesheet.validate(nil)

    assert {:ok, command} =
             Command.new(%{
               request_id: "r1",
               type: :conversation_init,
               params: %{stylesheet_url: nil}
             })

    assert command.params == %{stylesheet_url: nil}
  end
end
