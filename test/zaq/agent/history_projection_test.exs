defmodule Zaq.Agent.HistoryProjectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.HistoryLifecycle

  property "projection validation preserves exact sources and monotone read cursors within the bound" do
    check all(
            cursor <- integer(0..10_000),
            advance <- integer(0..1_000),
            count <- integer(0..151)
          ) do
      id = "transcript"
      history = %{projection: %{transcript_id: id}, cursors: %{id => cursor}}

      projection = %{
        kind: :canonical,
        transcript_id: id,
        cursors: %{id => cursor + advance},
        messages: List.duplicate(%{}, count)
      }

      assert :ok = HistoryLifecycle.validate_projection(history, projection)

      assert {:error, :invalid_history_cursor} =
               HistoryLifecycle.validate_projection(history, %{
                 projection
                 | cursors: %{"foreign" => cursor}
               })

      assert {:error, :invalid_history_projection} =
               HistoryLifecycle.validate_projection(history, %{
                 projection
                 | messages: List.duplicate(%{}, 152)
               })
    end
  end
end
