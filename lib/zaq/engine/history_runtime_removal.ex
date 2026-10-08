defmodule Zaq.Engine.HistoryRuntimeRemoval do
  @moduledoc """
  Publishes committed Person/history removals to discovered Agent owner nodes.

  Membership owns the authoritative diff. This module only stages transactional
  retry work and invokes the provider-neutral lifecycle notification. Agent nodes
  acknowledge cancellation of their own incarnations; discovery is not proof of
  delivery to disconnected or undiscovered nodes.
  """

  alias Zaq.Contracts.HistoryRuntimeRemoval, as: Contract
  alias Zaq.Engine.HistoryRuntimeRemovalWorker
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo

  @doc "Stages a removal in the membership transaction without executing runtime effects."
  def stage(transcript_id, person_ids, generation \\ 1)
  def stage(_transcript_id, [], _generation), do: []

  def stage(transcript_id, person_ids, generation) do
    payload = %{
      event_id: Ecto.UUID.generate(),
      transcript_id: transcript_id,
      person_ids: Enum.sort(Enum.uniq(person_ids)),
      generation: generation
    }

    with :ok <- Contract.validate(payload),
         {:ok, _} <- payload |> HistoryRuntimeRemovalWorker.new() |> Oban.insert() do
      [payload]
    else
      _ -> Repo.rollback(:runtime_removal_enqueue_failed)
    end
  end

  @doc "Returns the original membership result only after committed local fanout succeeds."
  def committed({:ok, result}) do
    {removals, public} = Map.pop(result, :runtime_removals, [])

    if Repo.in_transaction?() do
      # An enclosing transaction owns commit. Only its committed Oban job may
      # perform effects; a rollback must never stop an Agent incarnation.
      {:ok, public}
    else
      if removals |> Enum.map(&dispatch/1) |> Enum.all?(&(&1 == :ok)),
        do: {:ok, public},
        else: {:error, :runtime_removal_pending}
    end
  end

  def committed(error), do: error

  @doc "Requests exact-incarnation cancellation on every currently discovered Agent node."
  def dispatch(payload) do
    with :ok <- Contract.validate(payload),
         {:ok, events} <-
           NodeRouter.dispatch_all(
             Event.new(payload, :agent,
               actor: %{kind: :system, subject: "engine:history-membership"},
               opts: [action: :history_membership_removed, confidential: true]
             )
           ),
         true <- Enum.all?(events, &match?(%Event{response: {:ok, _}}, &1)) do
      :ok
    else
      {:error, :invalid_history_removal} = error -> error
      _ -> {:error, :runtime_removal_unavailable}
    end
  end
end
