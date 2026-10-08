defmodule Zaq.Agent.HistoryLoader do
  @moduledoc """
  Loads recent conversation history from the DB and converts it to a
  `Jido.AI.Context` struct for injection into a cold-started agent process.
  Also converts and merges Engine-authorized canonical projections for request-local
  refresh, without mutating retained runtime context or owning authorization.

  This module is the only place that performs DB→Jido.AI.Context conversion.
  It is completely independent of `Zaq.Agent.History`, which serves the
  non-Jido retrieval and BO chat paths.
  """

  import Ecto.Query

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.OpaqueAliases
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Repo
  alias Zaq.Utils.DateUtils

  @max_db_fetch 500

  @doc "Converts an Engine-authorized canonical projection without querying storage or permissions."
  @spec from_projection([map()], keyword()) :: AIContext.t()
  def from_projection(messages, opts \\ []) do
    Enum.reduce(messages, AIContext.new(), fn message, context ->
      role = if message.role == "assistant", do: :assistant, else: :user
      author = Enum.reject([message[:author_name], message[:author_id]], &is_nil/1)

      label =
        case author do
          [name, id] -> "#{name} (#{id})"
          [value] -> value
          [] -> "Unknown author"
        end

      content =
        history_content(
          %{
            content: "#{label}: #{message.content}",
            metadata: %{attachments: message.attachments}
          },
          opts
        )

      AIContext.append(context, %AIContext.Entry{
        role: role,
        content: content,
        timestamp: message.provider_sent_at,
        refs: Map.take(message, [:message_id, :transcript_id, :position])
      })
    end)
  end

  @doc "Merges canonical additions into a request-local context, retaining active tool exchanges."
  def merge_projection(%AIContext{} = context, messages, opts \\ []) do
    known = MapSet.new(context.entries, fn entry -> Map.get(entry.refs || %{}, :message_id) end)

    additions =
      messages
      |> Enum.reject(&MapSet.member?(known, &1.message_id))
      |> Enum.uniq_by(& &1.message_id)
      |> from_projection(opts)

    {history, active} =
      context.entries
      |> Enum.reverse()
      |> Enum.split_while(fn entry ->
        entry.role == :system or is_binary(Map.get(entry.refs || %{}, :transcript_id)) or
          Map.get(entry.refs || %{}, :history_completed, false)
      end)

    %{context | entries: Enum.reverse(history ++ Enum.reverse(additions.entries) ++ active)}
  end

  @doc "Binds the completed native answer to its persisted UUID without replacing tool exchanges."
  def bind_completed_answer(context, message_id, content \\ nil)

  def bind_completed_answer(%AIContext{} = context, message_id, content)
      when is_binary(message_id) do
    case context.entries do
      [%AIContext.Entry{role: :assistant} = entry | rest] ->
        entry = %{entry | refs: Map.put(entry.refs || %{}, :message_id, message_id)}
        entry = if is_binary(content), do: %{entry | content: content}, else: entry
        %{context | entries: [entry | rest]}

      _ ->
        context
    end
  end

  def bind_completed_answer(context, _message_id, _content), do: context

  @doc "Merges the completed request and marks retained exchanges as history for the next turn."
  def complete_projection(%AIContext{} = context, messages, opts \\ []) do
    context = merge_projection(context, messages, opts)

    %{
      context
      | entries:
          Enum.map(context.entries, fn entry ->
            %{entry | refs: Map.put(entry.refs || %{}, :history_completed, true)}
          end)
    }
  end

  @doc """
  Selects and loads the appropriate history context from a spawn opts map.

  Routes to `load_for_conversation/2` when `:conversation_id` is present,
  otherwise falls back to `load/3` using `:person_id` + `:channel_type`.

  Loads at most #{@max_db_fetch} rows. Model context-window enforcement happens
  later when projecting a concrete outbound LLM request.
  """
  @spec load_context(map(), keyword()) :: AIContext.t()
  def load_context(spawn_opts, opts \\ []) do
    conversation_id = Map.get(spawn_opts, :conversation_id)

    if is_binary(conversation_id) and conversation_id != "" do
      load_for_conversation(conversation_id, opts)
    else
      load(Map.get(spawn_opts, :person_id), Map.get(spawn_opts, :channel_type), opts)
    end
  end

  defp fetch_messages_for_conversations(conversation_ids_query) do
    from(m in Message,
      where: m.conversation_id in subquery(conversation_ids_query),
      order_by: [desc: m.inserted_at],
      limit: @max_db_fetch,
      select: %{
        role: m.role,
        content: m.content,
        metadata: m.metadata,
        inserted_at: m.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Loads the most recent messages for the given `conversation_id` and returns a
  `Jido.AI.Context`.

  Returns an empty context immediately when `conversation_id` is `nil` or `""`.
  """
  @spec load_for_conversation(String.t() | nil, keyword()) :: AIContext.t()
  def load_for_conversation(conversation_id, opts \\ [])
  def load_for_conversation(nil, _opts), do: AIContext.new()
  def load_for_conversation("", _opts), do: AIContext.new()

  def load_for_conversation(conversation_id, opts) do
    from(m in Message,
      where:
        m.conversation_id == ^conversation_id and
          fragment("COALESCE(?->>'execution_status', 'completed') = 'completed'", m.metadata),
      order_by: [desc: m.inserted_at],
      limit: @max_db_fetch,
      select: %{
        role: m.role,
        content: m.content,
        metadata: m.metadata,
        inserted_at: m.inserted_at
      }
    )
    |> Repo.all()
    |> Enum.reverse()
    |> build_context(opts)
  end

  @doc """
  Loads the most recent messages for the given `person_id` + `channel_type` pair
  and returns a `Jido.AI.Context`.

  Returns an empty context immediately when `person_id` is `nil`.
  """
  @spec load(integer() | nil, String.t() | nil, keyword()) :: AIContext.t()
  def load(person_id, channel_type, opts \\ [])
  def load(nil, _channel_type, _opts), do: AIContext.new()
  def load(_person_id, nil, _opts), do: AIContext.new()

  def load(person_id, channel_type, opts) do
    messages = fetch_recent_messages(person_id, channel_type)

    messages
    |> Enum.reverse()
    |> build_context(opts)
  end

  defp fetch_recent_messages(person_id, channel_type) do
    conv_ids =
      from(c in Conversation,
        where: c.person_id == ^person_id and c.channel_type == ^channel_type,
        select: c.id
      )

    fetch_messages_for_conversations(conv_ids)
  end

  defp build_context(messages, opts) do
    Enum.reduce(messages, AIContext.new(), fn
      %{role: "user", inserted_at: ts} = message, ctx ->
        AIContext.append(ctx, %AIContext.Entry{
          role: :user,
          content: "[#{DateUtils.format_ts(ts)}] #{history_content(message, opts)}",
          timestamp: ts
        })

      %{role: "assistant", content: content, inserted_at: ts}, ctx ->
        AIContext.append(ctx, %AIContext.Entry{
          role: :assistant,
          content: content || "",
          timestamp: ts
        })

      _other, ctx ->
        ctx
    end)
  end

  defp history_content(message, opts) when is_map(message) do
    content = Map.get(message, :content) || ""
    metadata = Map.get(message, :metadata)

    case safe_attachments(metadata, Keyword.get(opts, :opaque_alias_scope)) do
      [] -> content
      attachments -> Enum.join([content, "Attachments:", Jason.encode!(attachments)], "\n")
    end
  end

  defp safe_attachments(metadata, scope) when is_map(metadata) do
    metadata
    |> Map.get("attachments", Map.get(metadata, :attachments, []))
    |> case do
      attachments when is_list(attachments) ->
        attachments
        |> Enum.filter(&is_map/1)
        |> Enum.map(&safe_attachment(&1, scope))

      _ ->
        []
    end
  end

  defp safe_attachments(_metadata, _scope), do: []

  defp safe_attachment(attachment, scope) do
    safe = Map.drop(attachment, ["content", :content, "raw", :raw])

    case scope do
      nil ->
        safe

      scope ->
        case OpaqueAliases.alias_metadata(safe, scope) do
          {:ok, aliased} -> aliased
          {:error, _reason} -> safe
        end
    end
  end
end
