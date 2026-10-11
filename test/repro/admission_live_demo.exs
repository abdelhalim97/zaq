# Manual, local-only review fixture. This is not a browser E2E test or approval.
# Use the branch-isolated E2E database; never run against a populated production DB.
# MIX_ENV=test E2E=1 MIX_BUILD_PATH=_build/test-e2e \
#   elixir --sname zaq_admission_demo -S mix run --no-halt test/repro/admission_live_demo.exs
# Control locally through :rpc.call(node, Zaq.Repro.AdmissionLiveDemo, :step, [step]).
defmodule Zaq.Repro.AdmissionLiveDemo do
  use GenServer

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Agent
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryMembership
  alias Zaq.Engine.Conversations.ExecutionRecord
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.Repo
  alias Zaq.TestSupport.{MattermostHistoryFixture, MultiAgentOpenAIStub, OpenAIStub}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def step(action), do: GenServer.call(__MODULE__, action)

  @impl true
  def init(opts) do
    repo = Application.fetch_env!(:zaq, Repo)

    unless System.get_env("E2E") == "1" &&
             String.starts_with?(repo[:database], "zaq_test_e2e_") &&
             repo[:hostname] in ["localhost", "127.0.0.1"] do
      raise "manual admission demo requires a local, branch-isolated E2E database"
    end

    for role <- ["super_admin", "admin", "staff"] do
      unless Accounts.get_role_by_name(role), do: Accounts.create_role(%{name: role, meta: %{}})
    end

    role = Accounts.get_role_by_name("super_admin")

    unless Accounts.get_user_by_username("admission_demo") do
      {:ok, admin} =
        Accounts.create_user_with_password(%{
          username: "admission_demo",
          email: "admission-demo@example.test",
          password: "LocalDemoPass1!",
          role_id: role.id
        })

      {:ok, _} = Accounts.update_user(admin, %{must_change_password: false})
    end

    owner = self()

    {http, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          if conn.request_path == "/v1/responses" do
            send(owner, {:demo_model_waiting, self()})

            receive do
              :release_demo_model -> :ok
            end

            request = Jason.decode!(body)

            {200,
             MultiAgentOpenAIStub.text_sse(
               "The input was admitted before access loss. Its answer completes normally.",
               request["model"]
             )}
          else
            MattermostHistoryFixture.http(conn, body, owner)
          end
        end,
        owner
      )

    {:ok, _} = Supervisor.start_link([http], strategy: :one_for_one)

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "local-demo-only"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: Keyword.get(opts, :label, "Admission review demo"),
        job: "Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        active: true,
        conversation_enabled: true,
        advanced_options: %{"stream" => false, "receive_timeout" => 120_000}
      })

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: Keyword.get(opts, :label, "Local admission demo"),
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: String.trim_trailing(endpoint, "/v1"),
        token: "local-demo-only",
        settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot"}}
      })
      |> Repo.insert!()

    {:ok, person} =
      People.create_person(%{
        full_name: "Alice — local admission demo",
        email: "admission-demo-#{config.id}@example.test",
        phone: "+33123456789"
      })

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "alice",
        channel_config_id: config.id
      })

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(
        %{channel_config_id: config.id},
        %{routing_mode: :agent, configured_agent_id: agent.id}
      )

    Application.put_env(:zaq, :channels, %{
      mattermost: %{
        bridge: JidoChatBridge,
        adapter: Jido.Chat.Mattermost.Adapter,
        ingress_mode: :webhook
      }
    })

    resource = ChannelHistoryResource.for("mattermost", config.id, "shared-room")
    IO.puts("Local admission demo ready: http://localhost:4002/bo/channels/history")

    {:ok,
     %{
       config: config,
       agent: agent,
       person: person,
       resource: resource,
       worker: nil,
       observer: Keyword.get(opts, :observer)
     }}
  end

  @impl true
  def handle_call(:start, _from, state) do
    result =
      MattermostHistoryFixture.post(state.config, nil, true, %{
        "id" => "admission-demo-root-#{state.config.id}",
        "message" => "@zaq Finish this admitted request even if my channel access changes."
      })

    {:reply, submission_result(result), state}
  end

  def handle_call(:revoke, _from, state) do
    {:ok, %{status: :applied}} =
      ChannelHistoryMembership.apply_event(%{
        provider: "mattermost",
        channel_config_id: state.config.id,
        channel_id: "shared-room",
        identity_platform: "mattermost",
        member_id: "alice",
        operation: :remove,
        revision: 2
      })

    {:reply, %{read_access: Permissions.can?(state.person, "read", state.resource)}, state}
  end

  def handle_call(:release, _from, %{worker: worker} = state) when is_pid(worker) do
    send(worker, :release_demo_model)
    {:reply, :ok, %{state | worker: nil}}
  end

  def handle_call(:new_input, _from, state) do
    result =
      MattermostHistoryFixture.post(state.config, nil, true, %{
        "id" => "admission-demo-denied-#{state.config.id}",
        "message" => "@zaq New input after access was revoked."
      })

    {:reply, submission_result(result), state}
  end

  def handle_call(:state, _from, state) do
    records =
      for suffix <- ["root", "denied"] do
        case Repo.get_by(Message,
               external_message_id: "admission-demo-#{suffix}-#{state.config.id}"
             ) do
          nil ->
            %{input: suffix, status: :not_sent}

          message ->
            execution = Repo.get_by(ExecutionRecord, user_message_id: message.id)

            %{
              input: suffix,
              message_id: message.id,
              status: execution && execution.status,
              admitted: execution && not is_nil(execution.admitted_at),
              answer_message_id: execution && execution.public_answer_message_id
            }
        end
      end

    {:reply,
     %{
       read_access: Permissions.can?(state.person, "read", state.resource),
       model_waiting: not is_nil(state.worker),
       records: records
     }, state}
  end

  @impl true
  def handle_info({:demo_model_waiting, worker} = message, state) do
    notify_observer(state, message)
    {:noreply, %{state | worker: worker}}
  end

  def handle_info(message, state) do
    notify_observer(state, message)
    {:noreply, state}
  end

  defp notify_observer(%{observer: observer}, message) when is_pid(observer),
    do: send(observer, message)

  defp notify_observer(_state, _message), do: :ok

  defp submission_result({{:ok, _}, _}), do: :submitted
  defp submission_result(_), do: :submission_failed
end

{:ok, _} = Zaq.Repro.AdmissionLiveDemo.start_link()
