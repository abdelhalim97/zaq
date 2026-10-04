defmodule Zaq.Engine.ChannelHistoryProjection do
  @moduledoc """
  Engine-local, page-bounded read model for authorized BO history lists.

  The caller supplies already scoped transcript rows. This module batches all
  participant, title, thread and locally stored root data for that finite page;
  it never dispatches provider requests.
  """

  import Ecto.Query

  alias Zaq.Accounts.{Person, PersonChannel}
  alias Zaq.Engine.Conversations.{Message, MessageRating, Transcript, TranscriptMessage}
  alias Zaq.Repo

  @doc "Projects one bounded transcript page without provider I/O."
  @spec project([map()]) :: [map()]
  def project([]), do: []

  def project(rows) when is_list(rows) do
    ids = Enum.map(rows, & &1.id)
    first_messages = first_messages(ids)
    roots = stored_roots(rows)

    people =
      rows
      |> Enum.map(& &1.owner_person_id)
      |> Kernel.++(Enum.map(Map.values(first_messages), &author_person_id/1))
      |> Kernel.++(Enum.map(Map.values(roots), &author_person_id/1))
      |> person_summaries()

    participants = participant_projection(rows)
    thread_counts = thread_counts(ids)
    identities = root_identities(rows, roots)
    ratings = rating_summaries(Enum.map(Map.values(roots), & &1.id))

    Enum.map(rows, fn row ->
      participant = Map.get(participants, row.id, %{recent: [], count: 0})
      root = Map.get(roots, row.id)

      Map.merge(row, %{
        owner: Map.get(people, row.owner_person_id),
        channel_name: history_title(Map.get(first_messages, row.id), row.channel_name, people),
        participants: participant.recent,
        participant_count: participant.count,
        thread_count: Map.get(thread_counts, row.id, 0),
        root_message: display_root(root, row, people, identities, ratings)
      })
    end)
  end

  defp participant_projection(rows) do
    request =
      Jason.encode!(
        Enum.map(rows, &%{id: &1.id, parent_id: &1.parent_id, thread_id: &1.thread_id})
      )

    Repo.query!(
      """
      WITH requested AS (
        SELECT id::uuid, parent_id::uuid, thread_id
        FROM jsonb_to_recordset($1::text::jsonb)
          AS row(id text, parent_id text, thread_id text)
      ), resolved AS (
        SELECT requested.id AS requested_id,
               person.id AS person_id,
               person.full_name AS display_name,
               max(COALESCE(message.provider_sent_at, message.inserted_at)) AS last_seen
        FROM requested
        JOIN transcripts transcript
          ON transcript.id = requested.id
          OR transcript.parent_id = requested.id
          OR transcript.id = requested.parent_id
        JOIN transcript_messages placement ON placement.transcript_id = transcript.id
        JOIN messages message ON message.id = placement.message_id
        LEFT JOIN channels identity
          ON identity.channel_config_id = transcript.channel_config_id
         AND message.history_context->>'author_person_id' IS NULL
         AND identity.platform = COALESCE(message.history_context->>'identity_platform', transcript.provider)
         AND identity.channel_identifier = message.author_id
        JOIN people person
          ON person.id = identity.person_id
          OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(COALESCE(message.history_context->'participants', '[]'::jsonb)) participant
            WHERE (participant->>'person_id')::bigint = ANY(array_prepend(person.id, person.merged_person_ids))
          )
        WHERE message.role != 'assistant'
          AND (
            (requested.parent_id IS NULL AND
              (transcript.id = requested.id OR transcript.parent_id = requested.id))
            OR
            (requested.parent_id IS NOT NULL AND
              (transcript.id = requested.id OR
                (transcript.id = requested.parent_id AND
                 message.external_message_id = requested.thread_id)))
          )
        GROUP BY requested.id, person.id, person.full_name
      ), ranked AS (
        SELECT resolved.*,
               count(*) OVER (PARTITION BY requested_id) AS participant_count,
               row_number() OVER (
                 PARTITION BY requested_id ORDER BY last_seen DESC, person_id ASC
               ) AS recent_rank
        FROM resolved
      )
      SELECT requested_id::text, person_id, display_name, participant_count
      FROM ranked
      WHERE recent_rank <= 3
      ORDER BY requested_id, recent_rank
      """,
      [request]
    ).rows
    |> Enum.reduce(%{}, fn [id, person_id, display_name, count], acc ->
      entry = Map.get(acc, id, %{recent: [], count: count})
      recent = entry.recent ++ [%{person_id: person_id, display_name: display_name}]
      Map.put(acc, id, %{entry | recent: recent})
    end)
  end

  defp thread_counts(ids) do
    Repo.all(
      from transcript in Transcript,
        where: transcript.parent_id in ^ids,
        group_by: transcript.parent_id,
        select: {transcript.parent_id, count(transcript.id)}
    )
    |> Map.new()
  end

  defp first_messages(ids) do
    Repo.all(
      from placement in TranscriptMessage,
        join: message in Message,
        on: message.id == placement.message_id,
        where: placement.transcript_id in ^ids and message.role != "assistant",
        distinct: placement.transcript_id,
        order_by: [asc: placement.transcript_id, asc: placement.position],
        select: {placement.transcript_id, message}
    )
    |> Map.new()
  end

  defp stored_roots(rows) do
    parent_ids = rows |> Enum.map(& &1.parent_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    thread_ids = rows |> Enum.map(& &1.thread_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if parent_ids == [] or thread_ids == [] do
      %{}
    else
      candidates =
        Repo.all(
          from placement in TranscriptMessage,
            join: message in Message,
            on: message.id == placement.message_id,
            where:
              placement.transcript_id in ^parent_ids and
                message.external_message_id in ^thread_ids,
            select: {placement.transcript_id, message.external_message_id, message}
        )
        |> Map.new(fn {parent_id, external_id, message} ->
          {{parent_id, external_id}, message}
        end)

      Map.new(rows, fn row -> {row.id, Map.get(candidates, {row.parent_id, row.thread_id})} end)
    end
  end

  defp person_summaries(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Repo.all(
      from person in Person,
        where: person.id in ^ids or fragment("? && ?::bigint[]", person.merged_person_ids, ^ids)
    )
    |> Enum.flat_map(fn person ->
      summary = %{person_id: person.id, display_name: person.full_name || "Unnamed person"}
      Enum.map([person.id | person.merged_person_ids], &{&1, summary})
    end)
    |> Map.new()
  end

  defp root_identities(rows, roots) do
    descriptors =
      rows
      |> Enum.flat_map(fn row ->
        case Map.get(roots, row.id) do
          nil ->
            []

          message ->
            platform = message.history_context["identity_platform"] || row.provider
            [{row.channel_config_id, platform, message.author_id}]
        end
      end)
      |> Enum.reject(fn {config_id, platform, author_id} ->
        is_nil(config_id) or is_nil(platform) or is_nil(author_id)
      end)
      |> Enum.uniq()

    config_ids = Enum.map(descriptors, &elem(&1, 0))
    platforms = Enum.map(descriptors, &elem(&1, 1))
    author_ids = Enum.map(descriptors, &elem(&1, 2))

    Repo.all(
      from identity in PersonChannel,
        join: person in Person,
        on: person.id == identity.person_id,
        where:
          identity.channel_config_id in ^config_ids and identity.platform in ^platforms and
            identity.channel_identifier in ^author_ids,
        select:
          {{identity.channel_config_id, identity.platform, identity.channel_identifier},
           %{person_id: person.id, display_name: person.full_name}}
    )
    |> Map.new()
  end

  @doc "Returns positive and negative rating totals for a bounded message set."
  def rating_summaries([]), do: %{}

  def rating_summaries(ids) do
    Repo.all(
      from rating in MessageRating,
        where: rating.message_id in ^ids,
        group_by: rating.message_id,
        select:
          {rating.message_id,
           %{
             positive: filter(count(rating.id), rating.rating >= 4),
             negative: filter(count(rating.id), rating.rating < 4)
           }}
    )
    |> Map.new()
  end

  defp history_title(nil, fallback, _people), do: fallback

  defp history_title(message, fallback, people) do
    context = message.history_context || %{}

    case {context["title_style"], context["author_person_id"]} do
      {style, id} when style in ["person", "person_subject"] ->
        format_person_title(style, id, context, message, people)

      _ ->
        fallback
    end
  end

  defp format_person_title(style, id, context, message, people) do
    name =
      case Map.get(people, id) do
        %{display_name: name} when is_binary(name) and name != "" -> name
        _ -> message.author_name || message.author_id || "Person"
      end

    if style == "person_subject",
      do: "#{name}: #{context["subject"] || "(No subject)"}",
      else: name
  end

  defp display_root(nil, _row, _people, _identities, _ratings), do: nil

  defp display_root(message, row, people, identities, ratings) do
    context = message.history_context || %{}
    platform = context["identity_platform"] || row.provider

    resolved =
      case context["author_person_id"] do
        id when is_integer(id) -> Map.get(people, id)
        _ -> Map.get(identities, {row.channel_config_id, platform, message.author_id})
      end

    author =
      resolved ||
        %{display_name: message.author_name || message.author_id || "Person", person_id: nil}

    %{
      message_id: message.id,
      author_id: message.author_id,
      author_name: message.author_name,
      role: message.role,
      content: message.content,
      attachments: message.attachments,
      provider_sent_at: message.provider_sent_at,
      inserted_at: message.provider_sent_at || message.inserted_at,
      display_name: author.display_name,
      person_id: author.person_id,
      feedback: nil,
      rating_summary: Map.get(ratings, message.id, %{positive: 0, negative: 0})
    }
  end

  defp author_person_id(nil), do: nil
  defp author_person_id(message), do: (message.history_context || %{})["author_person_id"]
end
