defmodule Zaq.TestSupport.HistoryMediaAdapter do
  @moduledoc false

  # Only the provider edge is replaced; routing, handle verification and the
  # communication bridge remain real in the delayed-history regression.
  def fetch_media(reference, opts) do
    url = Keyword.fetch!(opts, :url) <> "/media/" <> URI.encode(reference)

    case Req.get(url, decode_body: false) do
      {:ok, %{status: 200, body: bytes}} -> {:ok, bytes}
      _ -> {:error, :media_unavailable}
    end
  end
end
