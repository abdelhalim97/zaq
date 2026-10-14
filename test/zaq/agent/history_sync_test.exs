defmodule Zaq.Agent.HistorySyncTest do
  use ExUnit.Case, async: true

  import Mox

  alias Zaq.Agent.HistorySync
  alias Zaq.Event

  setup :verify_on_exit!

  test "execution admission fails closed for an unmatched Engine response" do
    binding = %{user_message_id: Ecto.UUID.generate(), execution_id: Ecto.UUID.generate()}
    actor = %{kind: :system, subject: "history-sync-test"}
    content = "confidential execution content"

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert %Event{
               request: %{binding: ^binding, content: ^content},
               next_hop: %{destination: :engine},
               actor: ^actor,
               opts: opts
             } = event

      assert opts[:action] == :admit_execution
      assert opts[:confidential]
      %{event | response: :unmatched}
    end)

    assert {:error, :history_unavailable} =
             HistorySync.execution_admission(
               [node_router: Zaq.NodeRouterMock],
               binding,
               actor,
               content
             )
  end
end
