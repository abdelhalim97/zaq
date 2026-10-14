defmodule ZaqWeb.Live.BO.Communication.AgentRoutingOptions do
  @moduledoc "Reusable BO routing inputs and conversion to canonical routing rule commands."

  use Phoenix.Component

  alias Zaq.Agent
  alias Zaq.Channels.AgentRouting
  alias Zaq.MapUtils
  alias Zaq.Utils.ParseUtils

  @none_value AgentRouting.none_value()

  @doc "Returns dropdown options with the centralized NONE choice prepended."
  @spec agent_options(module() | list()) :: [{String.t(), term()}]
  def agent_options(agents \\ Agent)

  def agent_options(agent_module) when is_atom(agent_module),
    do: agent_options(agent_module.list_conversation_enabled_agents())

  def agent_options(agents) when is_list(agents) do
    [{"NONE", AgentRouting.none_value()}] ++
      Enum.map(agents, fn agent ->
        {agent.name, agent.id}
      end)
  end

  attr :id, :string, required: true
  attr :form, :string, required: true
  attr :scope, :map, required: true
  attr :value, :any, default: ""
  attr :options, :list, required: true
  attr :label, :string, default: nil
  attr :default_label, :string, default: "Default"
  attr :errors, :list, default: []
  attr :hint, :string, default: nil
  attr :hint_id, :string, default: nil

  @doc "Uses the shared BO select with the same rule-field contract for every routing scope."
  def rule_select(assigns) do
    assigns = assign(assigns, :name, "#{assigns.form}[rules][#{rule_key(assigns.scope)}]")

    ~H"""
    <input
      :for={{key, value} <- @scope}
      :if={!is_nil(value)}
      type="hidden"
      name={"#{@name}[#{key}]"}
      value={value}
    />
    <ZaqWeb.Select.select
      id={@id}
      name={"#{@name}[choice]"}
      value={@value}
      label={@label}
      options={[{@default_label, ""} | @options]}
      errors={@errors}
      hint={@hint}
      hint_id={@hint_id}
    />
    """
  end

  @doc "Stable form key, including arbitrary topic names without interpreting them as form paths."
  def rule_key(scope) do
    topic = MapUtils.fetch(scope, :topic_id) || ""

    Enum.join(
      [
        MapUtils.fetch(scope, :channel_config_id),
        MapUtils.fetch(scope, :retrieval_channel_id),
        Base.url_encode64(topic, padding: false)
      ],
      ":"
    )
  end

  @doc "Converts shared rule inputs to the existing Engine command shape without querying domain data."
  def form_rules(nil), do: {:ok, []}

  def form_rules(fields) when is_map(fields) do
    fields
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {_, field}, {:ok, rules} ->
      case form_rule(field) do
        {:ok, rule} -> {:cont, {:ok, rules ++ [rule]}}
        error -> {:halt, error}
      end
    end)
  end

  def form_rules(_), do: {:error, :invalid_routing_selection}

  defp form_rule(field) when is_map(field) do
    with {:ok, scope} <- form_scope(field),
         {:ok, choice} <- form_choice(Map.get(field, "choice")),
         do: {:ok, AgentRouting.rule_attrs(scope, choice)}
  end

  defp form_rule(_), do: {:error, :invalid_routing_selection}

  defp form_scope(field) do
    with {:ok, scope} <- topic_scope(field["topic_id"]) do
      Enum.reduce_while(
        [:person_id, :channel_config_id, :retrieval_channel_id],
        {:ok, scope},
        fn key, acc -> form_scope_id(field[to_string(key)], key, acc) end
      )
    end
  end

  defp form_scope_id(nil, _key, acc), do: {:cont, acc}

  defp form_scope_id(raw, key, {:ok, scope}) do
    case ParseUtils.parse_int_strict(raw) do
      {:ok, id} when id > 0 -> {:cont, {:ok, Map.put(scope, key, id)}}
      _ -> {:halt, {:error, :invalid_routing_selection}}
    end
  end

  defp topic_scope(nil), do: {:ok, %{}}
  defp topic_scope(topic) when is_binary(topic), do: {:ok, %{topic_id: topic}}
  defp topic_scope(_), do: {:error, :invalid_routing_selection}

  defp form_choice(choice) when choice in [nil, ""], do: {:ok, nil}
  defp form_choice(@none_value), do: {:ok, :none}

  defp form_choice(choice) do
    case ParseUtils.parse_int_strict(choice) do
      {:ok, id} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_agent}
    end
  end
end
