defmodule Zaq.Channels.WebBridge do
  @moduledoc """
  Bridge for normalized web consumers, including BO ChatLive and the web widget.

  It translates shared web Message values into canonical `%Incoming{}` messages,
  delegates non-message Commands through Engine role actions, and delivers
  `%Outgoing{}` responses through the configured web delivery contract.

  The legacy BO path remains compatible during migration: each ChatLive session
  subscribes to `"chat:<session_id>"`, status updates use `:upsert_message`, and
  final results use `send_reply/2`.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.CommunicationBridge

  alias Zaq.Channels.{Bridge, CommunicationBridge}
  alias Zaq.Channels.Web.{Command, Context, Response}
  alias Zaq.Channels.Web.Message, as: WebMessage
  alias Zaq.Engine.Conversations.{Conversation, MessageRating}
  alias Zaq.Engine.Conversations.Message, as: ConversationMessage
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.Events.Helper
  alias Zaq.NodeRouter

  @doc "Receives a normalized web payload through the common bridge ingress hooks."
  @spec from_listener(map(), WebMessage.t() | Command.t(), keyword()) ::
          Outgoing.t() | Response.t() | :ok | {:error, term()}
  def from_listener(config, payload, sink_opts) when is_map(config) and is_list(sink_opts) do
    Bridge.route_incoming(__MODULE__, config, payload, sink_opts)
  end

  @doc false
  def handle_from_listener(_config, %WebMessage{} = message, sink_opts) do
    with {:ok, context} <- fetch_context(sink_opts),
         actor when is_map(actor) <- context.actor || {:error, :unauthorized} do
      message
      |> to_internal(context)
      |> CommunicationBridge.route_incoming_message(
        pipeline_opts(context, sink_opts),
        actor,
        node_router_opts(sink_opts)
      )
    end
  end

  def handle_from_listener(_config, %Command{} = command, sink_opts) do
    with {:ok, context} <- fetch_context(sink_opts),
         actor when is_map(actor) <- context.actor || {:error, :unauthorized} do
      handle_command(command, context, sink_opts, actor)
    end
  end

  @doc """
  Builds `%Incoming{provider: :web}` from ChatLive form params.

  Expected params keys: `:content`, `:channel_id` (optional, defaults to `"bo"`),
  `:session_id`, `:request_id`.
  """
  @spec to_internal(WebMessage.t() | map(), Context.t() | map()) :: Incoming.t()
  @impl true
  def to_internal(params, connection_details \\ %{})

  def to_internal(%WebMessage{} = message, %Context{} = context) do
    Incoming.new(%{
      content: message.content,
      channel_id: message.channel,
      author_id: message.author_id,
      author_name: message.author_name,
      message_id: message.message_id,
      provider: :web,
      attachments: message.attachments,
      content_filter: context.content_filter,
      routing_context: %{
        conversation_id: message.conversation_id,
        provider_sent_at: message.timestamp,
        attributes: routing_attributes(context)
      },
      metadata: %{
        request_id: message.request_id,
        user_content: message.content,
        conversation_id: message.conversation_id,
        session_id: legacy_session_id(context.delivery)
      }
    })
  end

  def to_internal(params, _connection_details) do
    Incoming.new(%{
      content: params[:content],
      channel_id: params[:channel_id] || "bo",
      message_id: params[:request_id],
      provider: :web,
      metadata: Map.take(params, [:session_id, :request_id, :user_content])
    })
  end

  @doc """
  Broadcasts `%Outgoing{}` to the originating ChatLive session via PubSub.

  The topic `"chat:<session_id>"` is derived from `outgoing.metadata[:session_id]`.
  The message format is `{:pipeline_result, request_id, outgoing, user_content}`
  to maintain compatibility with the ChatLive handler.
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  @impl true
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    session_id = outgoing.metadata[:session_id]
    request_id = outgoing.metadata[:request_id]
    user_content = outgoing.metadata[:user_content]

    Phoenix.PubSub.broadcast(
      Zaq.PubSub,
      "chat:#{session_id}",
      {:pipeline_result, request_id, outgoing, user_content}
    )
  end

  @impl true
  def upsert_message(_config, request, _connection_details) when is_map(request) do
    request_id = Map.get(request, :request_id)
    session_id = Map.get(request, :session_id)
    message = Map.get(request, :body)

    if Helper.present?(request_id) and Helper.present?(session_id) and Helper.present?(message) do
      stage = status_stage(Map.get(request, :intent_meta))

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "chat:#{session_id}",
        {:status_update, request_id, stage, message, Map.get(request, :update_intent)}
      )

      message_id = Map.get(request, :message_id) || request_id
      action = if Helper.present?(Map.get(request, :message_id)), do: :updated, else: :created

      {:ok,
       %{action: action, message_id: message_id, update_intent: Map.get(request, :update_intent)}}
    else
      {:ok, %{action: :noop, message_id: nil, update_intent: Map.get(request, :update_intent)}}
    end
  end

  defp status_stage(%{} = intent_meta) do
    case Map.get(intent_meta, :stage) || Map.get(intent_meta, "stage") do
      stage when is_atom(stage) -> stage
      _ -> :answering
    end
  end

  defp status_stage(_), do: :answering

  defp fetch_context(sink_opts) do
    case Keyword.get(sink_opts, :context) do
      %Context{} = context -> {:ok, context}
      _ -> {:error, :missing_web_context}
    end
  end

  defp pipeline_opts(%Context{} = context, sink_opts) do
    [
      history: context.history,
      skip_permissions: MapSet.member?(context.capabilities, :skip_permissions),
      node_router: Keyword.get(sink_opts, :node_router, NodeRouter)
    ]
  end

  defp node_router_opts(sink_opts),
    do: [node_router: Keyword.get(sink_opts, :node_router, NodeRouter)]

  defp routing_attributes(%Context{selected_agent_id: nil}), do: %{}

  defp routing_attributes(%Context{selected_agent_id: id}) do
    %{"configured_agent_id" => id, "routing_source" => "bo_explicit"}
  end

  defp legacy_session_id(%{consumer: :bo, topic: "chat:" <> session_id}), do: session_id
  defp legacy_session_id(_delivery), do: nil

  defp handle_command(%Command{type: :conversation_init} = command, context, sink_opts, actor) do
    case resolve_conversation(command, context, sink_opts, actor) do
      {:ok, conversation, details} ->
        response(command, :conversation_initialized, conversation.id, details)

      {:error, reason} ->
        error_response(command, reason)
    end
  end

  defp handle_command(
         %Command{type: :conversation_history, conversation_id: nil} = command,
         _context,
         _sink_opts,
         _actor
       ),
       do: error_response(command, :conversation_id_required)

  defp handle_command(
         %Command{type: :conversation_history, conversation_id: conversation_id} = command,
         _context,
         sink_opts,
         actor
       ) do
    with %Conversation{} = conversation <-
           dispatch_conversation(
             %{action: :get, conversation_id: conversation_id},
             sink_opts,
             actor
           ),
         messages when is_list(messages) <-
           dispatch_conversation(
             %{action: :messages, conversation: conversation},
             sink_opts,
             actor
           ) do
      response(command, :conversation_history, conversation.id, %{
        conversation: conversation_projection(conversation),
        messages: Enum.map(messages, &message_projection/1)
      })
    else
      nil -> error_response(command, :conversation_not_found)
      {:error, reason} -> error_response(command, reason)
      _ -> error_response(command, :history_unavailable)
    end
  end

  defp resolve_conversation(%Command{conversation_id: nil}, context, sink_opts, actor),
    do: create_conversation(context, sink_opts, actor, %{})

  defp resolve_conversation(
         %Command{conversation_id: conversation_id},
         context,
         sink_opts,
         actor
       ) do
    case dispatch_conversation(
           %{action: :get, conversation_id: conversation_id},
           sink_opts,
           actor
         ) do
      %Conversation{} = conversation ->
        {:ok, conversation, %{created: false}}

      nil ->
        create_conversation(context, sink_opts, actor, %{replaced_missing_id: conversation_id})

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :conversation_unavailable}
    end
  end

  defp create_conversation(context, sink_opts, actor, details) do
    with {:ok, user_id} <- actor_user_id(context.actor),
         {:ok, %Conversation{} = conversation} <-
           dispatch_conversation(
             %{
               action: :create,
               attrs: %{
                 channel_user_id: "bo_user_#{user_id}",
                 channel_type: "bo",
                 user_id: user_id
               }
             },
             sink_opts,
             actor
           ) do
      {:ok, conversation, Map.put(details, :created, true)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :conversation_create_failed}
    end
  end

  defp dispatch_conversation(request, sink_opts, actor) do
    event = Event.new(request, :engine, actor: actor, opts: [action: :conversation])
    node_router = Keyword.get(sink_opts, :node_router, NodeRouter)

    case node_router.dispatch(event) do
      %Event{response: response} -> response
      _ -> {:error, :engine_unavailable}
    end
  end

  defp actor_user_id(%{user_id: id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp actor_user_id(%{"user_id" => id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp actor_user_id(_actor), do: {:error, :unauthorized}

  defp response(command, type, conversation_id, payload) do
    case Response.new(%{
           request_id: command.request_id,
           type: type,
           conversation_id: conversation_id,
           payload: payload
         }) do
      {:ok, response} -> response
      {:error, _reason} -> error_response(command, :invalid_response_payload)
    end
  end

  defp error_response(command, reason) do
    {:ok, response} =
      Response.new(%{
        request_id: command.request_id,
        type: :error,
        conversation_id: command.conversation_id,
        payload: %{code: safe_error_code(reason)}
      })

    response
  end

  defp safe_error_code(reason) when is_atom(reason), do: reason
  defp safe_error_code({reason, _details}) when is_atom(reason), do: reason
  defp safe_error_code(_reason), do: :operation_failed

  defp conversation_projection(%Conversation{} = conversation) do
    Map.take(conversation, [:id, :title, :status, :inserted_at, :updated_at])
  end

  defp message_projection(%ConversationMessage{} = message) do
    %{
      id: message.id,
      role: message.role,
      content: message.content,
      sources: message.sources,
      confidence_score: message.confidence_score,
      metadata: message.metadata,
      trace: message.trace,
      ratings: Enum.map(message.ratings, &rating_projection/1),
      inserted_at: message.inserted_at
    }
  end

  defp rating_projection(%MessageRating{} = rating),
    do: Map.take(rating, [:id, :rating, :reason, :comment])
end
