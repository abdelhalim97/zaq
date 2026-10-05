defmodule Zaq.Channels.Web.Runtime do
  @moduledoc """
  Host construction hook for adapter-owned widget runtimes.

  The configured server module builds child specs using the shared contracts and
  a fixed sink. ZAQ owns no widget endpoint; the adapter owns authentication,
  embedding/origin enforcement and subscription authorization. Payloads cannot
  select a builder, override widget ID or replace the configuration-bound sink.
  """

  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.ConnectorConfig.WidgetSettings
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Builds adapter-owned specs from server configuration, without a package dependency."
  def build(%{provider: provider, id: id} = config)
      when provider in [:web_widget, "web_widget"] do
    definition = Application.get_env(:zaq, :channels, %{}) |> Map.get(:web_widget, %{})
    builder = Map.get(definition, :runtime_builder)
    settings = Map.get(config, :settings, %{}) || %{}

    hooks = %{
      widget_id: id,
      allowed_domains: Map.get(settings, "allowed_domains", []),
      display_name: Map.get(settings, "display_name", Map.get(config, :name)),
      stylesheet_url: Map.get(settings, "stylesheet_url"),
      message: Message,
      command: Command,
      context: Context,
      delivery: Delivery,
      response: Response,
      sink_mfa: {__MODULE__, :from_listener, [config]}
    }

    if validate_settings(settings) == :ok and is_integer(id) and id > 0 and
         is_atom(builder) and not is_nil(builder) and Code.ensure_loaded?(builder) and
         function_exported?(builder, :build, 2) do
      normalize_specs(builder.build(config, hooks))
    else
      {:error, :widget_runtime_not_configured}
    end
  rescue
    _error -> {:error, :widget_runtime_construction_failed}
  end

  def build(_config), do: {:ok, {nil, []}}

  @doc "Validates persisted widget presentation/embedding inputs; endpoint enforcement is adapter-owned."
  defdelegate validate_settings(settings), to: WidgetSettings, as: :validate

  defp normalize_specs({:ok, {state, listeners}})
       when (is_nil(state) or is_map(state)) and is_list(listeners),
       do: {:ok, {state, listeners}}

  defp normalize_specs({:error, _} = error), do: error
  defp normalize_specs(_result), do: {:error, :invalid_widget_runtime_specs}

  @doc "Receives only normalized shared payloads and adapter-verified, config-bound Context."
  def from_listener(%{id: id}, payload, opts) when is_list(opts) do
    case Keyword.get(opts, :context) do
      %Context{consumer: :widget, channel_config_id: ^id} = context -> dispatch(payload, context)
      _ -> {:error, :unauthorized}
    end
  end

  def from_listener(_config, _payload, _opts), do: {:error, :unauthorized}

  defp dispatch(payload, context)
       when is_struct(payload, Message) or is_struct(payload, Command) do
    Event.new(%{payload: payload, context: context}, :channels, opts: [action: :web_ingress])
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp dispatch(_payload, _context), do: {:error, :invalid_payload}
end
