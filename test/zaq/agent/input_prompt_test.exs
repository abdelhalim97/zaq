defmodule Zaq.Agent.InputPromptTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.InputPrompt

  describe "append_attachments/3" do
    test "preserves the prompt when every nonempty-list entry is invalid" do
      assert InputPrompt.append_attachments("Keep this request", [nil, 42, "not a record"], nil) ==
               "Keep this request"
    end

    test "ignores invalid entries while formatting valid attachment metadata" do
      assert InputPrompt.append_attachments(
               "Keep this request",
               [%{"name" => "photo.png"}, nil],
               nil
             ) == "Keep this request\nAttachments:\n[{\"name\":\"photo.png\"}]"
    end
  end
end
