defmodule Zaq.Engine.Conversations.ExecutionLifecycle do
  @moduledoc """
  Persists private execution state within Conversations' admission/finalization
  transactions. Callers hold the admitted-message lock; this module never creates
  public messages, transcript placements, accounting jobs or delivery attempts.
  """

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations.ExecutionRecord
  alias Zaq.Identity.ExecutionActor
  alias Zaq.Repo

  @doc "Creates the private root for a newly admitted canonical Person input."
  def admit(%{person_id: id}, input, token, {:ok, _provider, _account_key})
      when is_integer(id) and id > 0 and is_binary(token) do
    %ExecutionRecord{}
    |> ExecutionRecord.changeset(%{
      person_id: id,
      user_message_id: input.id,
      finalization_token_hash: input.metadata["finalization_token_hash"]
    })
    |> Repo.insert()
  end

  def admit(_conversation, _input, _token, _source), do: {:ok, nil}

  @doc "Checks the literal active execution owner, including finalization replays."
  def authorize(input, actor) do
    case Repo.get_by(ExecutionRecord, user_message_id: input.id) do
      nil -> :ok
      execution -> authorize_owner(execution, actor)
    end
  end

  defp authorize_owner(execution, actor) do
    with {:ok, %{person: %{id: id}}} <- ExecutionActor.validate(actor),
         true <- id == execution.person_id,
         %Person{status: "active"} <- Repo.get(Person, id) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Returns whether the locked input belongs to the new private storage contract."
  def private?(input), do: not is_nil(Repo.get_by(ExecutionRecord, user_message_id: input.id))

  @doc "Stores one terminal root disposition; public-answer uniqueness remains schema-enforced."
  def finish(input, answer_id, status, trace, usage, outcome) do
    case Repo.get_by(ExecutionRecord, user_message_id: input.id) do
      nil ->
        {:ok, nil}

      execution ->
        execution
        |> ExecutionRecord.changeset(%{
          status: status,
          public_answer_message_id: answer_id,
          trace_entries: trace,
          tool_results: Enum.filter(trace, &(&1["type"] == "tool_call")),
          usage: usage,
          outcome: outcome
        })
        |> Repo.update()
    end
  end
end
