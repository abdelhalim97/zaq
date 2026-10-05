defmodule Zaq.ConnectorConfig.WidgetSettings do
  @moduledoc """
  Pure validation of persisted widget presentation and embedding settings.

  Engine connector persistence and Channels runtime construction share this
  value contract. It does not build runtimes, authenticate senders or enforce
  endpoint access; those responsibilities remain with their existing owners.
  """

  @doc "Validates the settings map without interpreting a browser-supplied widget identity."
  @spec validate(term()) :: :ok | {:error, :invalid_widget_settings}
  def validate(settings) when is_map(settings) do
    valid =
      not Map.has_key?(settings, "widget_id") and not Map.has_key?(settings, :widget_id) and
        valid_name?(Map.get(settings, "display_name")) and
        valid_domains?(Map.get(settings, "allowed_domains", [])) and
        valid_style?(Map.get(settings, "stylesheet_url"))

    if valid, do: :ok, else: {:error, :invalid_widget_settings}
  end

  def validate(_settings), do: {:error, :invalid_widget_settings}

  defp valid_name?(nil), do: true

  defp valid_name?(name) when is_binary(name),
    do: String.trim(name) != "" and byte_size(name) <= 200

  defp valid_name?(_name), do: false

  defp valid_domains?(domains) when is_list(domains),
    do: length(domains) <= 100 and Enum.all?(domains, &valid_origin?/1)

  defp valid_domains?(_domains), do: false

  defp valid_origin?(origin) when is_binary(origin) and byte_size(origin) <= 2_048 do
    uri = URI.parse(origin)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      not String.contains?(uri.host, "*") and is_nil(uri.userinfo) and uri.path in [nil, ""] and
      is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_origin?(_origin), do: false

  defp valid_style?(nil), do: true

  defp valid_style?(path) when is_binary(path),
    do:
      String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
        not String.contains?(path, ["..", "\\", "?", "#"]) and byte_size(path) <= 2_048

  defp valid_style?(_path), do: false
end
