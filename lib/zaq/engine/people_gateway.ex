defmodule Zaq.Engine.PeopleGateway do
  @moduledoc """
  Dispatches BO people-domain commands from Engine boundary actions.
  """

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PeopleAuth
  alias Zaq.Accounts.PeoplePermissions
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.AgentRouting
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.MapUtils
  alias Zaq.Repo

  def dispatch(:filter, %{filters: filters, opts: opts}) when is_map(filters) and is_list(opts),
    do: People.filter_people(filters, opts)

  def dispatch(:resolve_selection, params), do: People.resolve_selection(params)

  def dispatch(:permissions_matrix, %{}), do: {:ok, PeoplePermissions.permissions_matrix()}

  def dispatch(:grant_permission, %{scope: scope, permission: permission}),
    do: PeoplePermissions.grant(scope, permission)

  def dispatch(:revoke_permission, %{scope: scope, permission: permission}),
    do: PeoplePermissions.revoke(scope, permission)

  def dispatch(:list_person_sessions, %{person_id: person_id, active_only: active_only})
      when is_boolean(active_only) do
    with {:ok, person_id} <- positive_id(person_id),
         %{} = person <- People.get_person(person_id) do
      PeopleAuth.list_sessions(person, active_only: active_only)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def dispatch(:revoke_person_session, %{person_id: person_id, session_id: session_id}) do
    with {:ok, person_id} <- positive_id(person_id),
         {:ok, session_id} <- uuid(session_id),
         %{} = person <- People.get_person(person_id) do
      PeopleAuth.revoke_session(person, session_id)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def dispatch(:revoke_all_person_sessions, %{person_id: person_id}) do
    with {:ok, person_id} <- positive_id(person_id),
         %{} = person <- People.get_person(person_id) do
      PeopleAuth.revoke_all_sessions(person)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def dispatch(:get_with_channels, %{id: id}) do
    case People.get_person_with_channels(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> {:ok, person}
    end
  end

  def dispatch(:get, %{id: id}) do
    case People.get_person(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> {:ok, person}
    end
  end

  def dispatch(:create, %{attrs: attrs}) when is_map(attrs), do: People.create_person(attrs)

  def dispatch(:update, %{id: id, attrs: attrs}) when is_map(attrs) do
    case People.get_person(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> People.update_person(person, attrs)
    end
  end

  def dispatch(:update_resource, %{id: id} = params) do
    attrs = Map.get(params, :attrs) || Map.get(params, "attrs") || %{}
    channels = Map.get(params, :channels) || Map.get(params, "channels") || []
    merge = Map.get(params, :merge) || Map.get(params, "merge") || %{}

    People.update_person_resource(normalize_id(id), attrs, channels, merge)
  end

  def dispatch(:delete, %{id: id}) do
    case People.get_person(normalize_id(id)) do
      nil -> {:error, :not_found}
      person -> People.delete_person(person)
    end
  end

  def dispatch(:bulk_delete, %{person_ids: person_ids}) when is_list(person_ids),
    do: People.bulk_delete_people(Enum.map(person_ids, &normalize_id/1))

  def dispatch(:merge, %{survivor_id: survivor_id, loser_id: loser_id}),
    do: People.merge_persons(normalize_id(survivor_id), normalize_id(loser_id))

  def dispatch(:search, %{query: query, exclude_ids: exclude_ids, limit: limit})
      when is_binary(query) and is_list(exclude_ids) and is_integer(limit),
      do: {:ok, People.search_people(query, exclude_ids, limit)}

  def dispatch(:assign_team, %{person_id: person_id, team_id: team_id}) do
    case People.get_person(normalize_id(person_id)) do
      nil -> {:error, :not_found}
      person -> People.assign_team(person, normalize_id(team_id))
    end
  end

  def dispatch(:unassign_team, %{person_id: person_id, team_id: team_id}) do
    case People.get_person(normalize_id(person_id)) do
      nil -> {:error, :not_found}
      person -> People.unassign_team(person, normalize_id(team_id))
    end
  end

  def dispatch(:channel_routing_targets, %{}) do
    targets =
      ChannelConfig.list_person_channel_targets()
      |> Enum.filter(&(&1.platform in PersonChannel.supported_platforms()))

    {:ok, targets}
  end

  def dispatch(:person_routing_rules, %{person_id: id}),
    do: {:ok, IncomingMessageRouting.list_person_rules(normalize_id(id))}

  def dispatch(:set_person_routing_agent, %{person_id: id, choice: raw_choice}) do
    with %{} = person <- People.get_person(normalize_id(id)),
         {:ok, choice} <- AgentRouting.validate_choice(raw_choice) do
      IncomingMessageRouting.apply_rule_commands(
        [AgentRouting.rule_attrs(%{person_id: person.id}, choice)],
        raw_errors: true
      )
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def dispatch(:add_channel, %{attrs: attrs} = params) when is_map(attrs),
    do: save_channel(fn -> People.add_channel(attrs) end, Map.get(params, :rules, []))

  def dispatch(:update_channel, %{id: id, attrs: attrs} = params) when is_map(attrs) do
    case find_channel(normalize_id(id)) do
      nil ->
        {:error, :not_found}

      channel ->
        save_channel(
          fn -> People.update_channel(channel, MapUtils.stringify_keys(attrs)) end,
          Map.get(params, :rules, [])
        )
    end
  end

  def dispatch(:delete_channel, %{id: id}) do
    case find_channel(normalize_id(id)) do
      nil -> {:error, :not_found}
      channel -> People.delete_channel(channel)
    end
  end

  def dispatch(:swap_channel_weights, %{a_id: a_id, b_id: b_id}) do
    with a when not is_nil(a) <- find_channel(normalize_id(a_id)),
         b when not is_nil(b) <- find_channel(normalize_id(b_id)) do
      People.swap_channel_weights(a, b)
    else
      _ -> {:error, :not_found}
    end
  end

  def dispatch(:list_teams, %{}), do: {:ok, People.list_teams()}

  def dispatch(:get_team, %{id: id}) do
    case People.get_team(normalize_id(id)) do
      nil -> {:error, :not_found}
      team -> {:ok, team}
    end
  end

  def dispatch(:create_team, %{attrs: attrs}) when is_map(attrs), do: People.create_team(attrs)

  def dispatch(:update_team, %{id: id, attrs: attrs}) when is_map(attrs) do
    case People.get_team(normalize_id(id)) do
      nil -> {:error, :not_found}
      team -> People.update_team(team, attrs)
    end
  end

  def dispatch(:delete_team, %{id: id}) do
    case People.get_team(normalize_id(id)) do
      nil -> {:error, :not_found}
      team -> People.delete_team(team)
    end
  end

  def dispatch(_op, _params), do: {:error, :unsupported_people_operation}

  defp save_channel(save, rules) do
    Repo.transaction(fn ->
      case save.() do
        {:ok, channel} -> persist_channel_routing(channel, rules)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp persist_channel_routing(channel, rules) do
    result =
      with {:ok, rules} <- validate_channel_rules(channel, rules),
           do: IncomingMessageRouting.apply_rule_commands(rules, raw_errors: true)

    case result do
      {:ok, _} ->
        channel

      {:error, reason} ->
        channel
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(
          :channel_config_id,
          "invalid routing selection: #{inspect(reason)}"
        )
        |> Repo.rollback()
    end
  end

  # Validate the canonical commands against the saved link, not BO form field names.
  # This also protects clear commands, which otherwise go directly to deletion.
  defp validate_channel_rules(_channel, []), do: {:ok, []}

  defp validate_channel_rules(channel, rules) when is_list(rules) do
    case ChannelConfig.list_person_channel_targets(channel.platform, channel.channel_config_id) do
      [%{incoming?: true} = target] ->
        Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, acc} ->
          validate_channel_rule(rule, channel, target, acc)
        end)

      _ ->
        {:error, :invalid_routing_target}
    end
  end

  defp validate_channel_rules(_, _), do: {:error, :invalid_routing_target}

  defp validate_channel_rule(rule, channel, target, acc) when is_map(rule) do
    rule = MapUtils.stringify_keys(rule)
    person_id = rule["person_id"]
    retrieval_id = rule["retrieval_channel_id"]
    topic = rule["topic_id"]

    valid? =
      matching_id?(rule["channel_config_id"], channel.channel_config_id) and
        (is_nil(person_id) or matching_id?(person_id, channel.person_id)) and
        valid_channel_rule_target?(retrieval_id, topic, target)

    if valid?,
      do: {:cont, {:ok, acc ++ [Map.put(rule, "person_id", channel.person_id)]}},
      else: {:halt, {:error, :invalid_routing_target}}
  end

  defp validate_channel_rule(_, _, _, _), do: {:halt, {:error, :invalid_routing_target}}

  defp valid_channel_rule_target?(nil, nil, _), do: true
  defp valid_channel_rule_target?(nil, topic, target), do: topic in target.topics

  defp valid_channel_rule_target?(id, nil, target),
    do: Enum.any?(target.retrieval_channels, &matching_id?(id, &1.id))

  defp valid_channel_rule_target?(_, _, _), do: false

  defp matching_id?(raw, expected), do: positive_id(raw) == {:ok, expected}

  defp find_channel(id) do
    People.get_channel(id)
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp normalize_id(id), do: id

  defp positive_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp positive_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_person_id}
    end
  end

  defp positive_id(_id), do: {:error, :invalid_person_id}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_session}
    end
  end

  defp uuid(_value), do: {:error, :invalid_session}
end
