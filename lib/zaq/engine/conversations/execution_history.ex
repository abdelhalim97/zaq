defmodule Zaq.Engine.Conversations.ExecutionHistory do
  @moduledoc """
  Composes bounded canonical context for an already-verified Engine admission.

  Conversations owns admission capability and actor validation. This internal
  composer selects the input's exact strategy scope and reuses TranscriptHistory
  authorization/sanitization for every source. It never fetches provider content
  or reads private execution payloads. Agent owns conversion to model context.
  """

  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations.{Transcript, TranscriptHistory, TranscriptMessage}
  alias Zaq.Repo

  @local_limit 100
  @parent_limit 50

  @doc "Resolves a verified input's canonical scope without granting fresh history access."
  def scope(input, conversation, %Person{id: person_id}) do
    case input_transcript(input, conversation, person_id) do
      %Transcript{id: id} -> {:ok, %{kind: :canonical, transcript_id: id}}
      _ -> {:error, :unauthorized}
    end
  end

  def scope(_input, _conversation, _person), do: {:error, :unauthorized}

  @doc "Projects verified admission history; use Conversations.execution_history/2 at boundaries."
  def project(input, conversation, person) do
    case project_admission(input, conversation, person) do
      {:error, {:history_access_denied, _}} -> {:error, :unauthorized}
      result -> result
    end
  end

  @doc "Projects history with a trusted access-denial coordinate after caller identity validation."
  def project_admission(%{source_provider: nil} = input, _conversation, _person) do
    canonical? =
      Repo.exists?(
        from p in TranscriptMessage,
          join: t in Transcript,
          on: t.id == p.transcript_id,
          where: p.message_id == ^input.id and t.strategy != "legacy"
      )

    if canonical?, do: {:error, :unauthorized}, else: {:ok, %{kind: :legacy}}
  end

  def project_admission(input, conversation, %Person{id: person_id} = person) do
    with %Transcript{} = transcript <- input_transcript(input, conversation, person_id),
         {:ok, local} <- read(person, transcript, @local_limit),
         {:ok, parent, root, cursors} <- parent_context(person, transcript) do
      messages =
        (root ++ parent ++ local)
        |> Enum.reject(&(&1.message_id == input.id))
        |> Enum.uniq_by(& &1.message_id)

      {:ok,
       %{
         kind: :canonical,
         transcript_id: transcript.id,
         cursors: Map.put(cursors, transcript.id, transcript.next_position),
         messages: messages
       }}
    else
      nil -> {:error, :unauthorized}
      {:error, _} = error -> error
    end
  end

  def project_admission(_input, _conversation, _person), do: {:error, :unauthorized}

  @doc "Reads bounded cumulative association additions without advancing a runtime cursor."
  def delta(input, conversation, person, cursors) do
    case delta_admission(input, conversation, person, cursors) do
      {:error, {:history_access_denied, _}} -> {:error, :unauthorized}
      result -> result
    end
  end

  @doc "Reads fresh history with a trusted denial after caller binding validation."
  def delta_admission(%{source_provider: nil}, _conversation, _person, _cursors),
    do: {:error, :unauthorized}

  def delta_admission(input, conversation, %Person{id: person_id} = person, cursors) do
    with %Transcript{} = transcript <- input_transcript(input, conversation, person_id),
         {:ok, sources} <- delta_sources(transcript),
         :ok <- validate_cursors(cursors, sources) do
      read_deltas(person, input, transcript, sources, cursors)
    else
      nil -> {:error, :unauthorized}
      {:error, _} = error -> error
    end
  end

  def delta_admission(_input, _conversation, _person, _cursors), do: {:error, :unauthorized}

  defp delta_sources(%{parent_id: nil} = transcript), do: {:ok, [{transcript, @local_limit}]}

  defp delta_sources(transcript) do
    case Repo.get(Transcript, transcript.parent_id) do
      %Transcript{} = parent -> {:ok, [{parent, @parent_limit}, {transcript, @local_limit}]}
      nil -> {:error, :unauthorized}
    end
  end

  defp validate_cursors(cursors, sources) when is_map(cursors) do
    valid? =
      map_size(cursors) == length(sources) and
        Enum.all?(sources, fn {source, _limit} ->
          cursor = Map.get(cursors, source.id)
          is_integer(cursor) and cursor >= 0 and cursor <= source.next_position
        end)

    if valid?, do: :ok, else: {:error, :invalid_history_cursor}
  end

  defp validate_cursors(_cursors, _sources), do: {:error, :invalid_history_cursor}

  defp read_deltas(person, input, transcript, sources, cursors) do
    initial = %{
      kind: :canonical,
      transcript_id: transcript.id,
      messages: [],
      cursors: %{},
      upper_cursors:
        Map.new(sources, fn {source, _limit} -> {source.id, source.next_position} end)
    }

    Enum.reduce_while(sources, {:ok, initial}, fn {source, limit}, {:ok, projection} ->
      case TranscriptHistory.list(person, source.id,
             trusted_access_denial: true,
             after_position: cursors[source.id],
             up_to_position: source.next_position,
             limit: limit
           ) do
        {:ok, messages} ->
          {:cont,
           {:ok, merge_delta(projection, messages, source.id, cursors[source.id], input.id)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp merge_delta(projection, messages, source_id, after_position, input_id) do
    # Advance only through associations actually read, including the active
    # input which is excluded from model history. A capped page cannot skip
    # the unseen remainder merely because we captured its upper bound.
    cursor =
      case List.last(messages) do
        nil -> after_position
        message -> message.position
      end

    messages = Enum.map(messages, &Map.put(&1, :transcript_id, source_id))

    merged =
      (projection.messages ++ messages)
      |> Enum.reject(&(&1.message_id == input_id))
      |> Enum.uniq_by(& &1.message_id)

    %{projection | messages: merged, cursors: Map.put(projection.cursors, source_id, cursor)}
  end

  defp input_transcript(input, _conversation, person_id) do
    query =
      from t in Transcript,
        join: p in TranscriptMessage,
        on: p.transcript_id == t.id,
        where:
          p.message_id == ^input.id and t.provider == ^input.source_provider and
            (is_nil(t.owner_person_id) or t.owner_person_id == ^person_id) and
            t.strategy != "legacy",
        limit: 2

    # Admission already proved the exact source and placement. Legacy conversation
    # coordinates are deliberately absent for some strategies (e.g. email).
    # Never pick an arbitrary replica if a merge leaves multiple literal copies.
    case Repo.all(query) do
      [transcript] -> transcript
      _ -> nil
    end
  end

  defp read(person, transcript, limit) do
    with {:ok, messages} <-
           TranscriptHistory.list(person, transcript.id,
             trusted_access_denial: true,
             after_position: max(0, transcript.next_position - limit),
             up_to_position: transcript.next_position,
             limit: limit
           ) do
      {:ok, Enum.map(messages, &Map.put(&1, :transcript_id, transcript.id))}
    end
  end

  defp parent_context(_person, %{parent_id: nil}), do: {:ok, [], [], %{}}

  defp parent_context(person, transcript) do
    with %Transcript{} = parent <- Repo.get(Transcript, transcript.parent_id),
         {:ok, background} <- read(person, parent, @parent_limit),
         {:ok, root} <-
           TranscriptHistory.list(person, parent.id,
             trusted_access_denial: true,
             limit: 1,
             up_to_position: parent.next_position,
             external_message_id: transcript.external_thread_id
           ) do
      {:ok, background, Enum.map(root, &Map.put(&1, :transcript_id, parent.id)),
       %{parent.id => parent.next_position}}
    else
      nil -> {:error, :unauthorized}
      {:error, _} = error -> error
    end
  end
end
