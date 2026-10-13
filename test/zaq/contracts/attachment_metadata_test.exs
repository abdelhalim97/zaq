defmodule Zaq.Contracts.AttachmentMetadataTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.Record

  test "durable attachment metadata excludes runtime and untrusted fields" do
    source = %{
      "version" => 1,
      "type" => "communication_media",
      "locator" => %{"reference" => "file"}
    }

    record = %Record{
      id: "file",
      kind: :file,
      name: "photo.png",
      size: 4,
      content: <<255>>,
      raw: %{token: "secret"},
      url: "https://provider.invalid",
      materialization_handle: "runtime",
      provenance_ref: "runtime-provenance",
      attributes: %{"materialization_source" => source, "token" => "secret"}
    }

    assert Record.attachment_metadata(record) == %{
             "id" => "file",
             "kind" => "file",
             "name" => "photo.png",
             "size" => 4,
             "attributes" => %{"materialization_source" => source}
           }
  end

  property "durable metadata is idempotent across JSON round trips" do
    check all(
            id <- string(:alphanumeric, min_length: 1, max_length: 128),
            size <- integer(0..100_000)
          ) do
      record = %Record{id: id, kind: :file, size: size, materialization_handle: "temporary"}
      metadata = Record.attachment_metadata(record)
      assert Record.attachment_metadata(Jason.decode!(Jason.encode!(metadata))) == metadata
      refute Map.has_key?(metadata, "materialization_handle")
    end
  end

  test "rejects malformed, oversized, and non-JSON source metadata" do
    for source <- [
          nil,
          "bad",
          %{self() => "bad"},
          %{"locator" => String.duplicate("x", 20_000)},
          %{"locator" => %{"token" => "secret"}},
          %{"nested" => [%{"content" => "bytes"}]}
        ] do
      assert Record.attachment_metadata(%{
               "id" => "file",
               "attributes" => %{"materialization_source" => source}
             }) == %{"id" => "file"}
    end
  end
end
