defmodule Storybook.Components.Forms.RoutingSelect do
  use PhoenixStorybook.Story, :component

  alias Zaq.Channels.AgentRouting
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions

  def function, do: &AgentRoutingOptions.rule_select/1

  def description,
    do: "Shared routing input: Default, NONE or an agent, with canonical rule scope fields."

  def variations do
    options = [{"NONE", AgentRouting.none_value()}, {"Support agent", 42}]

    [
      %Variation{
        id: :connector_default,
        attributes: %{
          id: "routing-provider",
          form: "channel",
          scope: %{channel_config_id: 12},
          value: "",
          options: options
        }
      },
      %Variation{
        id: :widget_default,
        attributes: %{
          id: "routing-widget",
          form: "widget",
          scope: %{},
          label: "Default agent",
          default_label: "Use inherited routing",
          value: "",
          options: options,
          hint: "Uses connector-scoped routing.",
          hint_id: "routing-widget-hint"
        }
      },
      %Variation{
        id: :retrieval_none,
        attributes: %{
          id: "routing-retrieval",
          form: "channel",
          scope: %{channel_config_id: 12, retrieval_channel_id: 34},
          value: AgentRouting.none_value(),
          options: options
        }
      },
      %Variation{
        id: :topic_agent,
        attributes: %{
          id: "routing-topic",
          form: "channel",
          scope: %{channel_config_id: 12, topic_id: "Support/INBOX"},
          value: "42",
          options: options
        }
      }
    ]
  end
end
