defmodule Zaq.ConnectorConfig.WidgetSettings do
  @moduledoc """
  Pure validation of persisted widget presentation, embedding and authentication settings.

  Stylesheet URLs belong to instance initialization, never connector settings.

  Engine connector persistence and Channels runtime construction share this
  value contract. It does not build runtimes, authenticate senders or enforce
  endpoint access; those responsibilities remain with their existing owners.
  """

  @defaults %{
    "identity_issuer" => "zaq_issuer",
    "identity_audience" => "zaq_audience",
    "same_site" => "None"
  }

  @doc "Defaults for new connectors only; legacy omitted settings retain their runtime policy."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "Validates the settings map without interpreting a browser-supplied widget identity."
  @spec validate(term()) :: :ok | {:error, :invalid_widget_settings}
  def validate(settings) when is_map(settings),
    do: if(validation_errors(settings) == %{}, do: :ok, else: {:error, :invalid_widget_settings})

  def validate(_settings), do: {:error, :invalid_widget_settings}

  @doc "Returns actionable validation messages keyed by the public widget setting field."
  @spec validation_errors(term()) :: %{optional(String.t()) => [String.t()]}
  def validation_errors(settings) when is_map(settings) do
    %{}
    |> maybe_error(
      forbidden_identity_or_stylesheet?(settings),
      "settings",
      "Widget identity and stylesheet settings cannot be persisted here."
    )
    |> maybe_error(
      not valid_name?(Map.get(settings, "display_name")),
      "display_name",
      "Use 1–200 non-blank characters."
    )
    |> add_domain_errors(Map.get(settings, "allowed_domains", []))
    |> add_identifier_error(settings, "identity_issuer")
    |> add_identifier_error(settings, "identity_audience")
    |> maybe_error(not valid_same_site?(settings), "same_site", "Choose None, Lax, or Strict.")
    |> maybe_error(
      Enum.any?([:identity_issuer, :identity_audience, :same_site], &Map.has_key?(settings, &1)),
      "settings",
      "Use string keys for widget authentication settings."
    )
  end

  def validation_errors(_settings), do: %{"settings" => ["Widget settings must be a map."]}

  defp forbidden_identity_or_stylesheet?(settings),
    do:
      Enum.any?(
        ["widget_id", :widget_id, "stylesheet_url", :stylesheet_url],
        &Map.has_key?(settings, &1)
      )

  defp maybe_error(errors, false, _field, _message), do: errors

  defp maybe_error(errors, true, field, message),
    do: Map.update(errors, field, [message], &(&1 ++ [message]))

  defp add_domain_errors(errors, domains) when is_list(domains) and length(domains) <= 100 do
    Enum.reduce(domains, errors, fn origin, acc ->
      if valid_origin?(origin),
        do: acc,
        else: maybe_error(acc, true, "allowed_domains", origin_error(origin))
    end)
  end

  defp add_domain_errors(errors, domains) when is_list(domains),
    do: maybe_error(errors, true, "allowed_domains", "Enter no more than 100 origins.")

  defp add_domain_errors(errors, _domains),
    do: maybe_error(errors, true, "allowed_domains", "Enter one exact HTTP(S) origin per line.")

  defp origin_error(origin) when is_binary(origin) do
    without_trailing_slash = String.trim_trailing(origin, "/")

    if without_trailing_slash != origin and valid_origin?(without_trailing_slash),
      do: "Remove the trailing slash: use #{without_trailing_slash}.",
      else: "Enter an exact HTTP(S) origin, for example https://example.com."
  end

  defp origin_error(_origin),
    do: "Enter an exact HTTP(S) origin, for example https://example.com."

  defp add_identifier_error(errors, settings, key) do
    case Map.fetch(settings, key) do
      :error ->
        errors

      {:ok, value} ->
        maybe_error(
          errors,
          not valid_identifier?(value),
          key,
          "Use 1–255 characters without leading or trailing spaces."
        )
    end
  end

  defp valid_same_site?(settings),
    do: optional_setting?(settings, "same_site", &(&1 in ["None", "Lax", "Strict"]))

  defp optional_setting?(settings, key, validate) do
    case Map.fetch(settings, key) do
      :error -> true
      {:ok, value} -> validate.(value)
    end
  end

  defp valid_identifier?(value) when is_binary(value),
    do: String.valid?(value) and byte_size(value) in 1..255 and String.trim(value) == value

  defp valid_identifier?(_value), do: false

  defp valid_name?(nil), do: true

  defp valid_name?(name) when is_binary(name),
    do: String.trim(name) != "" and byte_size(name) <= 200

  defp valid_name?(_name), do: false

  defp valid_origin?(origin) when is_binary(origin) and byte_size(origin) <= 2_048 do
    uri = URI.parse(origin)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      not String.contains?(uri.host, "*") and is_nil(uri.userinfo) and uri.path in [nil, ""] and
      is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp valid_origin?(_origin), do: false
end
