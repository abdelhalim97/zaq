defmodule Zaq.Agent.InputPrompt do
  @moduledoc """
  Formats admitted input attachments for ordinary execution and native controls.

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
      Enum.map(attachments, fn attachment ->
        case OpaqueAliases.alias_record_metadata(attachment, scope) do
          {:ok, metadata} -> metadata
          {:error, _reason} -> Record.metadata(attachment)
        end
      end)

    Enum.join([content, "Attachments:", Jason.encode!(metadata)], "\n")
  end

  def append_attachments(content, _attachments, _scope), do: content
end
