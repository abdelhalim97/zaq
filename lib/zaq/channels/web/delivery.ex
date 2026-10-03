defmodule Zaq.Channels.Web.Delivery do
  @moduledoc """
  Trusted adapter delivery descriptor for semantic WebBridge responses.

  Adapters provide a validated server-resolved topic and map supported semantic
  response names to their expected wire event names. Browser payloads must never
  construct or override this descriptor.
  """

  alias Zaq.Channels.Web.Validation

  @semantic_events [
    :widget_initialized,
    :conversation_initialized,
    :conversation_created,
    :conversation_history,
    :typing,
    :message_create,
    :message_edit,
    :message_step,
    :message_complete,
    :message_failed,
    :status,
    :error
  ]

  @allowed_fields [:consumer, :topic, :protocol_version, :events, :channel_config_id]
  @enforce_keys [:consumer, :topic, :protocol_version, :events]
  defstruct @enforce_keys ++ [:channel_config_id]

  @type t :: %__MODULE__{
          consumer: :bo | :widget,
          topic: String.t(),
          protocol_version: pos_integer(),
          events: map(),
          channel_config_id: pos_integer() | nil
        }

  @doc "Builds a trusted adapter delivery descriptor."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Validation.reject_unknown_fields(attrs, @allowed_fields),
         {:ok, consumer} <- consumer(Validation.fetch(attrs, :consumer)),
         {:ok, topic} <-
           Validation.identifier(Validation.fetch(attrs, :topic), :topic, required: true),
         {:ok, protocol_version} <- protocol_version(Validation.fetch(attrs, :protocol_version)),
         {:ok, events} <- events(Validation.fetch(attrs, :events)),
         {:ok, channel_config_id} <-
           channel_config_id(Validation.fetch(attrs, :channel_config_id)) do
      {:ok,
       %__MODULE__{
         consumer: consumer,
         topic: topic,
         protocol_version: protocol_version,
         events: events,
         channel_config_id: channel_config_id
       }}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :delivery}}

  @doc "Builds the legacy BO delivery descriptor used during migration."
  @spec bo(String.t()) :: t()
  def bo(topic) do
    {:ok, delivery} =
      new(%{
        consumer: :bo,
        topic: topic,
        protocol_version: 1,
        events: %{
          status: :status_update,
          message_complete: :pipeline_result,
          message_failed: :pipeline_result,
          error: :pipeline_result
        }
      })

    delivery
  end

  defp consumer(consumer) when consumer in [:bo, :widget], do: {:ok, consumer}
  defp consumer(_consumer), do: {:error, {:invalid_field, :consumer}}

  defp protocol_version(nil), do: {:ok, 1}
  defp protocol_version(1), do: {:ok, 1}
  defp protocol_version(_version), do: {:error, {:invalid_field, :protocol_version}}

  defp events(nil), do: {:ok, %{}}

  defp events(events) when is_map(events) do
    case Enum.find(Map.keys(events), &(&1 not in @semantic_events)) do
      nil -> validate_event_names(events)
      event -> {:error, {:invalid_event, event}}
    end
  end

  defp events(_events), do: {:error, {:invalid_field, :events}}

  defp validate_event_names(events) do
    if Enum.all?(events, fn {_semantic, name} -> valid_event_name?(name) end) do
      {:ok, events}
    else
      {:error, {:invalid_field, :events}}
    end
  end

  defp valid_event_name?(name) when is_atom(name), do: true
  defp valid_event_name?(name) when is_binary(name), do: String.trim(name) != ""
  defp valid_event_name?(_name), do: false

  defp channel_config_id(nil), do: {:ok, nil}
  defp channel_config_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp channel_config_id(_id), do: {:error, {:invalid_field, :channel_config_id}}
end
