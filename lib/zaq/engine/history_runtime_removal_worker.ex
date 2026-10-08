defmodule Zaq.Engine.HistoryRuntimeRemovalWorker do
  @moduledoc """
  Transactional retry adapter for HistoryRuntimeRemoval's committed notification.
  Never reconciles grants or interprets provider membership.
  """
  use Oban.Worker, queue: :default, max_attempts: 10

  alias Zaq.Engine.HistoryRuntimeRemoval

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "event_id" => event_id,
            "transcript_id" => transcript_id,
            "person_ids" => ids,
            "generation" => generation
          } = args
      })
      when map_size(args) == 4 do
    result =
      HistoryRuntimeRemoval.dispatch(%{
        event_id: event_id,
        transcript_id: transcript_id,
        person_ids: ids,
        generation: generation
      })

    if result == {:error, :invalid_history_removal},
      do: {:cancel, :invalid_history_removal},
      else: result
  end

  def perform(_), do: {:cancel, :invalid_history_removal}
end
