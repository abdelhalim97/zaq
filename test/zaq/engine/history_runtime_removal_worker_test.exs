defmodule Zaq.Engine.HistoryRuntimeRemovalWorkerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.HistoryRuntimeRemovalWorker

  property "obsolete jobs are inert only for canonical references and positive stable Person IDs" do
    check all(ids <- list_of(positive_integer(), min_length: 1, max_length: 30)) do
      payload = %{
        event_id: Ecto.UUID.generate(),
        transcript_id: Ecto.UUID.generate(),
        person_ids: ids,
        generation: 1
      }

      assert :ok = perform(payload)

      for invalid <- [
            Map.put(payload, :token, "untrusted"),
            %{payload | event_id: "wrong"},
            %{payload | transcript_id: nil},
            %{payload | person_ids: [nil | ids]},
            %{payload | person_ids: [0 | ids]},
            %{payload | person_ids: []},
            %{payload | generation: 0},
            %{payload | generation: nil}
          ] do
        assert {:cancel, :invalid_history_removal} = perform(invalid)
      end
    end
  end

  test "malformed or unbounded removal scopes are rejected" do
    for value <- [
          nil,
          %{},
          [],
          "event",
          %{
            event_id: Ecto.UUID.generate(),
            transcript_id: Ecto.UUID.generate(),
            person_ids: List.duplicate(1, 10_001)
          }
        ] do
      assert {:cancel, :invalid_history_removal} = perform(value)
    end
  end

  defp perform(payload) when is_map(payload),
    do:
      HistoryRuntimeRemovalWorker.perform(%Oban.Job{
        args: Map.new(payload, fn {key, value} -> {to_string(key), value} end)
      })

  defp perform(value), do: HistoryRuntimeRemovalWorker.perform(%Oban.Job{args: value})
end
