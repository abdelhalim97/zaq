defmodule Zaq.Contracts.HistoryRuntimeRemoval do
  @moduledoc """
  Provider-neutral internal notification of committed history membership removal.

  This validates transport shape only, not caller authority. Engine publishes
  explicit system-principal events; Agent owns exact-incarnation cancellation.
  No admission token, provider identifier, or message content crosses this seam.
  """

  @doc "Validates one immutable event identifier, canonical source and bounded Person set."
  def validate(
        %{
          event_id: event_id,
          transcript_id: transcript_id,
          person_ids: ids,
          generation: generation
        } = payload
      )
      when map_size(payload) == 4 and is_list(ids) and length(ids) in 1..10_000 and
             is_integer(generation) and generation > 0 do
    if valid_uuid?(event_id) and valid_uuid?(transcript_id) and
         Enum.all?(ids, &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, :invalid_history_removal}
    end
  end

  def validate(_), do: {:error, :invalid_history_removal}

  defp valid_uuid?(id), do: is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id))
end
