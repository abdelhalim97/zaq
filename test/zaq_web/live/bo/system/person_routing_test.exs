defmodule ZaqWeb.Live.BO.System.PersonRoutingTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.AgentRouting
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Engine.PeopleGateway
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions
  alias ZaqWeb.Live.BO.System.PersonRouting
  import Zaq.CommunicationFixtures
  import Zaq.SystemConfigFixtures

  test "nil person produces default values for every routing scope" do
    assert PersonRouting.person_global_agent_value(nil) == ""
    assert PersonRouting.person_provider_agent_value(nil, %ChannelConfig{id: 1}) == ""
    assert PersonRouting.person_retrieval_agent_value(nil, %RetrievalChannel{id: 1}) == ""
    assert PersonRouting.person_topic_agent_value(nil, %ChannelConfig{id: 1}, "INBOX") == ""
  end

  test "person routing values resolve only their exact persisted scope" do
    person = person_fixture()
    channel = channel_fixture(person)
    retrieval = insert_retrieval_channel!(channel.channel_config_id)
    agent = insert_agent!()

    scopes = [
      {%{person_id: person.id}, :none},
      {%{person_id: person.id, channel_config_id: channel.channel_config_id}, :agent},
      {%{
         person_id: person.id,
         channel_config_id: channel.channel_config_id,
         retrieval_channel_id: retrieval.id
       }, :none},
      {%{person_id: person.id, channel_config_id: channel.channel_config_id, topic_id: "INBOX"},
       :agent}
    ]

    Enum.each(scopes, fn {scope, mode} ->
      attrs =
        if mode == :agent,
          do: %{routing_mode: mode, configured_agent_id: agent.id},
          else: %{routing_mode: mode}

      assert {:ok, _} = IncomingMessageRouting.upsert_rule(scope, attrs)
    end)

    assert PersonRouting.person_global_agent_value(person) == AgentRouting.none_value()

    assert PersonRouting.person_provider_agent_value(person, %ChannelConfig{
             id: channel.channel_config_id
           }) == AgentRouting.select_value(agent.id)

    assert PersonRouting.person_retrieval_agent_value(person, retrieval) ==
             AgentRouting.none_value()

    assert PersonRouting.person_topic_agent_value(
             person,
             %ChannelConfig{id: channel.channel_config_id},
             "INBOX"
           ) == AgentRouting.select_value(agent.id)

    assert PersonRouting.person_provider_agent_value(person, %ChannelConfig{
             id: channel.channel_config_id + 1
           }) == ""

    assert PersonRouting.person_retrieval_agent_value(person, %{retrieval | id: retrieval.id + 1}) ==
             ""

    assert PersonRouting.person_topic_agent_value(
             person,
             %ChannelConfig{id: channel.channel_config_id},
             "OTHER"
           ) == ""
  end

  test "non-channel values have no available routing configs" do
    assert PersonRouting.person_channel_routing_configs(nil) == []
    assert PersonRouting.person_channel_routing_configs(%{}) == []
  end

  test "malformed provider config key returns invalid routing choice without persisting" do
    person = person_fixture()

    assert_invalid_rules(channel_fixture(person), [
      %{channel_config_id: "not-an-id", routing_mode: :none}
    ])

    assert_no_person_routing_rules(person)
  end

  test "invalid provider choice returns its validation error without persisting" do
    person = person_fixture()

    channel = channel_fixture(person)

    assert_invalid_rules(channel, [
      %{channel_config_id: channel.channel_config_id, routing_mode: :none},
      %{
        channel_config_id: channel.channel_config_id,
        routing_mode: :agent,
        configured_agent_id: "bad-agent-choice"
      }
    ])

    assert_no_person_routing_rules(person)
  end

  test "malformed retrieval channel key returns invalid channel without persisting" do
    person = person_fixture()

    channel = channel_fixture(person)

    assert_invalid_rules(channel, [
      %{
        channel_config_id: channel.channel_config_id,
        retrieval_channel_id: "not-an-id",
        routing_mode: :none
      }
    ])

    assert_no_person_routing_rules(person)
  end

  test "malformed topic config key returns invalid topic rule without persisting" do
    person = person_fixture()

    assert_invalid_rules(channel_fixture(person), [
      %{channel_config_id: "not-an-id", topic_id: "INBOX", routing_mode: :none}
    ])

    assert_no_person_routing_rules(person)
  end

  property "canonical rule commands cannot escape the saved link, including clear requests" do
    check all(
            violation <- member_of([:connector, :owner, :retrieval, :topic, :mixed]),
            mode <- member_of([:none, :clear]),
            offset <- integer(1..1000),
            max_runs: 20
          ) do
      person = person_fixture()
      channel = channel_fixture(person)
      rule = %{channel_config_id: channel.channel_config_id, routing_mode: mode}

      forged =
        case violation do
          :connector -> Map.put(rule, :channel_config_id, channel.channel_config_id + offset)
          :owner -> Map.put(rule, :person_id, person.id + offset)
          :retrieval -> Map.put(rule, :retrieval_channel_id, -offset)
          :topic -> Map.put(rule, :topic_id, "unselected-#{offset}")
          :mixed -> Map.merge(rule, %{retrieval_channel_id: offset, topic_id: "unselected"})
        end

      assert_invalid_rules(channel, [Map.put(rule, :routing_mode, :none), forged])
      assert People.get_channel(channel.id).channel_identifier == channel.channel_identifier
      assert_no_person_routing_rules(person)
    end
  end

  test "the shared BO adapter emits rule commands without domain queries and rejects malformed choices" do
    input = %{
      "one" => %{"channel_config_id" => "123", "choice" => AgentRouting.none_value()},
      "two" => %{"channel_config_id" => "123", "topic_id" => "folder[a]/INBOX", "choice" => ""}
    }

    assert {:ok, [none, clear]} = AgentRoutingOptions.form_rules(input)
    assert none.routing_mode == :none
    assert clear.routing_mode == :clear
    assert clear.topic_id == "folder[a]/INBOX"
    assert clear.channel_config_id == 123

    assert {:error, :invalid_agent} =
             AgentRoutingOptions.form_rules(%{"one" => %{"choice" => "bad-agent-choice"}})

    assert {:error, :invalid_routing_selection} =
             AgentRoutingOptions.form_rules(%{"one" => "not-a-rule"})
  end

  defp assert_invalid_rules(channel, rules) do
    assert {:error, changeset} =
             PeopleGateway.dispatch(:update_channel, %{
               id: channel.id,
               attrs: %{channel_identifier: "changed-#{channel.id}"},
               rules: rules
             })

    assert errors_on(changeset).channel_config_id != []
  end

  defp person_fixture do
    unique_id = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(%{
        "full_name" => "Person Routing #{unique_id}",
        "email" => "person-routing-#{unique_id}@example.com"
      })

    person
  end

  defp channel_fixture(person) do
    {:ok, channel} =
      People.add_channel(
        scoped_channel_attrs(%{
          person_id: person.id,
          platform: "discord",
          channel_identifier: "#{person.id}"
        })
      )

    assert %PersonChannel{} = channel
    channel
  end

  defp assert_no_person_routing_rules(%Person{id: person_id}) do
    rules =
      Repo.all(
        from rule in IncomingMessageRoutingRule,
          where: rule.person_id == ^person_id
      )

    assert rules == []
  end

  defp insert_retrieval_channel!(channel_config_id) do
    %RetrievalChannel{}
    |> RetrievalChannel.changeset(%{
      channel_config_id: channel_config_id,
      channel_id: "person-routing-#{System.unique_integer([:positive, :monotonic])}",
      channel_name: "Person routing",
      team_id: "team-1",
      team_name: "Team",
      active: true
    })
    |> Repo.insert!()
  end

  defp insert_agent! do
    credential = ai_credential_fixture()

    %ConfiguredAgent{}
    |> ConfiguredAgent.changeset(%{
      name: "Person routing #{System.unique_integer([:positive, :monotonic])}",
      description: "",
      job: "Route incoming messages",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: true,
      active: true,
      advanced_options: %{}
    })
    |> Repo.insert!()
  end
end
