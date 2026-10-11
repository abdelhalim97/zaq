defmodule Zaq.Engine.HistoryRuntimeRemovalWorker do
  @moduledoc """
  Terminal adapter for obsolete serialized membership-removal jobs during rollout.
  Valid old jobs are acknowledged without notifying or cancelling Agent runtimes.
  No new jobs are produced. Remove after the persisted queue has drained.
  """
  use Oban.Worker, queue: :default, max_attempts: 10

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
      when map_size(args) == 4 and is_list(ids) and length(ids) in 1..10_000 and
             is_integer(generation) and generation > 0 do
    if valid_uuid?(event_id) and valid_uuid?(transcript_id) and
         Enum.all?(ids, &(is_integer(&1) and &1 > 0)),
       do: :ok,
       else: {:cancel, :invalid_history_removal}
  end

  def perform(_), do: {:cancel, :invalid_history_removal}

  defp valid_uuid?(id), do: is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id))
end
