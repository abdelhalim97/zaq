defmodule Zaq.Agent.InputPrompt do
  @moduledoc """
  Formats current and hydrated historical attachments for model input and native controls.

  Admission uses the original content. This request-local formatting only supplies
  record metadata and aliases scoped to the exact runtime; it does not authorize
  records or change canonical message identity.
  """

  alias Zaq.Agent.OpaqueAliases
  alias Zaq.Contracts.Record

  @spec append_attachments(term(), list(), term()) :: term()
  def append_attachments(content, attachments, scope)
      when is_binary(content) and is_list(attachments) and attachments != [] do
    metadata =
      attachments
      |> Enum.filter(&is_map/1)
      |> Enum.map(&attachment_metadata(&1, scope))

    if metadata == [],
      do: content,
      else: Enum.join([content, "Attachments:", Jason.encode!(metadata)], "\n")
  end

  def append_attachments(content, _attachments, _scope), do: content

  defp attachment_metadata(%Record{} = record, scope),
    do: attachment_metadata(Record.metadata(record), scope)

  defp attachment_metadata(metadata, scope) do
    safe =
      metadata
      |> Map.drop(["content", :content, "raw", :raw])
      |> Map.new(fn
        {key, attributes} when key in [:attributes, "attributes"] and is_map(attributes) ->
          {key, Map.drop(attributes, ["materialization_source", :materialization_source])}

        entry ->
          entry
      end)

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
