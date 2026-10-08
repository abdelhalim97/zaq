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

  import Ecto.Query

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

  @doc "Links one pending admitted input to a live root without transferring answer ownership."
  def queue(root_input, child_input) do
    root = Repo.get_by(ExecutionRecord, user_message_id: root_input.id)
    child = Repo.get_by(ExecutionRecord, user_message_id: child_input.id)

    queue_records(root, child, child_input.id)
  end

  defp queue_records(
         %ExecutionRecord{id: id, status: status},
         %ExecutionRecord{root_execution_id: id},
         _input_id
       )
       when status in ["completed", "failed"],
       do: {:error, :terminal_request}

  defp queue_records(root, child, input_id) do
    with %ExecutionRecord{root_execution_id: nil} <- root,
         %ExecutionRecord{status: "pending", root_execution_id: nil, person_id: person_id} <-
           child,
         true <- person_id == root.person_id do
      link_input(root, child, input_id)
    else
      {:error, _} = error -> error
      _ -> {:error, :input_conflict}
    end
  end

  defp link_input(root, child, input_id) do
    {status, outcome} =
      if root.status == "pending",
        do: {"queued", child.outcome},
        else: {"unconsumed", Map.put(child.outcome, "reason", "terminal_request")}

    with {:ok, child} <-
           child
           |> ExecutionRecord.changeset(%{
             root_execution_id: root.id,
             status: status,
             outcome: outcome
           })
           |> Repo.update() do
      if status == "queued" do
        {:ok,
         %{
           execution_id: child.id,
           root_execution_id: root.id,
           refs: %{message_id: input_id, execution_id: child.id, root_execution_id: root.id}
         }}
      else
        {:rejected, :terminal_request}
      end
    end
  end

  @doc "Marks only this root's queued receipt as consumed, idempotently."
  def consume(root_input, child_input) do
    root = Repo.get_by(ExecutionRecord, user_message_id: root_input.id)
    child = Repo.get_by(ExecutionRecord, user_message_id: child_input.id)

    with :ok <- pending_root(root),
         %ExecutionRecord{root_execution_id: root_id, status: status} <- child,
         true <- root_id == root.id and status in ["queued", "consumed"] do
      case child |> ExecutionRecord.changeset(%{status: "consumed"}) |> Repo.update() do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :input_conflict}
    end
  end

  defp pending_root(%ExecutionRecord{root_execution_id: nil, status: "pending"}), do: :ok
  defp pending_root(%ExecutionRecord{}), do: {:error, :terminal_request}
  defp pending_root(_), do: {:error, :unauthorized}

  @doc "Seals a rejected queued child, preserving consumption and terminal receipt evidence."
  def reject(root_input, child_input, reason) do
    root = Repo.get_by(ExecutionRecord, user_message_id: root_input.id)
    child = Repo.get_by(ExecutionRecord, user_message_id: child_input.id)

    with %ExecutionRecord{root_execution_id: nil, id: root_id} <- root,
         %ExecutionRecord{root_execution_id: ^root_id} <- child do
      reject_child(child, reason)
    else
      _ -> {:error, :input_conflict}
    end
  end

  defp reject_child(%ExecutionRecord{status: "consumed"}, _reason), do: {:error, :input_consumed}
  defp reject_child(%ExecutionRecord{status: "unconsumed"}, _reason), do: :ok

  defp reject_child(%ExecutionRecord{status: "queued"} = child, reason) do
    safe_reason =
      if reason in [:stale_runtime, :terminal_request, :scope_conflict],
        do: Atom.to_string(reason),
        else: "runtime_rejected"

    case child
         |> ExecutionRecord.changeset(%{
           status: "unconsumed",
           outcome: Map.put(child.outcome, "reason", safe_reason)
         })
         |> Repo.update() do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp reject_child(_child, _reason), do: {:error, :input_conflict}

  @doc "Stores one terminal root disposition; public-answer uniqueness remains schema-enforced."
  def finish(input, answer_id, status, trace, usage, outcome) do
    case Repo.get_by(ExecutionRecord, user_message_id: input.id) do
      nil ->
        {:ok, nil}

      execution ->
        from(child in ExecutionRecord,
          where: child.root_execution_id == ^execution.id and child.status == "queued"
        )
        |> Repo.update_all(set: [status: "unconsumed", updated_at: DateTime.utc_now()])

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
