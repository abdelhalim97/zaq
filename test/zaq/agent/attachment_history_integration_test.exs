defmodule Zaq.Agent.AttachmentHistoryIntegrationTest do
  use Zaq.DataCase, async: false

  alias Jido.Chat.{Author, ChannelMeta, Media}
  alias Jido.Chat.Incoming, as: ChatIncoming
  alias Zaq.Accounts.People
  alias Zaq.Agent.{Executor, ServerManager}
  alias Zaq.Channels.{CommunicationBridge, JidoChatBridge}
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryIngress}
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.TestSupport.{HistoryMediaAdapter, IntegrationAgent, MultiAgentOpenAIStub, OpenAIStub}

  test "media-only capture remains downloadable by a later agent after runtime restart" do
    owner = self()

    bytes =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5WQAAAAASUVORK5CYII="
      )

    handler = fn conn, body ->
      cond do
        conn.request_path == "/v1/media/native-file" ->
          send(owner, :downloaded_history_media)
          {200, bytes}

        MultiAgentOpenAIStub.tool_result?(body) ->
          assert body =~ Base.encode64(bytes)
          send(owner, :model_consumed_history_media)

          {200,
           MultiAgentOpenAIStub.text_sse("The historical image was analysed.", "gpt-4.1-mini")}

        true ->
          refute body =~ "materialization_source"
          refute body =~ "channel_config_id"
          [_, handle] = Regex.run(~r/(mat_[A-Za-z0-9_-]+)/, body)
          send(owner, {:model_history_alias, handle})

          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "download_document",
             %{materialization_handle: handle},
             model: "gpt-4.1-mini"
           )}
      end
    end

    {server, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(server)
    Code.ensure_loaded!(HistoryMediaAdapter)
    channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :mattermost, %{bridge: JidoChatBridge, adapter: HistoryMediaAdapter})
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, channels) end)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "History media",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: endpoint,
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Media author"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "media-author",
        channel_config_id: config.id
      })

    source = %ChatIncoming{
      text: nil,
      external_room_id: "history-media-room",
      external_message_id: "media-message",
      author: %Author{user_id: "media-author", user_name: "Media author"},
      raw: %{
        "channel_type" => "O",
        "post" => %{"channel_id" => "history-media-room", "user_id" => "media-author"}
      },
      channel_meta: %ChannelMeta{
        adapter_name: :mattermost,
        external_room_id: "history-media-room",
        is_dm: false,
        chat_type: :public
      },
      media: [
        %Media{
          kind: :image,
          filename: "photo.png",
          media_type: "image/png",
          size_bytes: byte_size(bytes),
          url: "https://wrong-provider-url.invalid/photo.png",
          metadata: %{file_id: "native-file"}
        }
      ]
    }

    incoming = JidoChatBridge.to_internal(source, %{provider: :mattermost, id: config.id})
    assert {:ok, capture} = HistoryIngress.capture(incoming)
    original = Repo.get!(Message, capture.message_id)
    assert original.content == ""
    assert [stored] = original.attachments
    refute Map.has_key?(stored, "materialization_handle")
    refute inspect(stored) =~ "wrong-provider-url"
    refute_received :downloaded_history_media

    {:ok, _} =
      Permissions.grant(
        ChannelHistoryResource.for("mattermost", config.id, incoming.channel_id),
        %{person_id: person.id, access_rights: ["read"]}
      )

    agent =
      IntegrationAgent.create!(
        endpoint,
        "delayed-media-#{Ecto.UUID.generate()}",
        "Analyse historical media using its download handle.",
        ["data_source.download_document"]
      )

    on_exit(fn -> ServerManager.stop_server(agent) end)

    for attempt <- 1..2 do
      question =
        Incoming.new(%{
          content: "Analyse the previously uploaded image",
          channel_id: incoming.channel_id,
          author_id: "media-author",
          author_name: person.full_name,
          person: person,
          provider: :mattermost,
          message_id: "analysis-#{attempt}",
          routing_context: %{channel_config_id: config.id, conversation_type: :room}
        })
        |> CommunicationBridge.put_conversation_identity()

      assert {:ok, _} = HistoryIngress.capture(question)
      assert {:ok, binding} = Conversations.admit_incoming(question)

      event =
        Event.new(question, :agent,
          actor: %{id: "media-author", person: %{id: person.id}, provider: :mattermost}
        )

      outgoing =
        Executor.run(question,
          agent_id: to_string(agent.id),
          conversation_binding: binding,
          conversation_id: binding.conversation_id,
          event: event
        )

      assert outgoing.metadata.error == false
      assert outgoing.body =~ "historical image was analysed"
      assert_receive {:model_history_alias, alias}, 5_000
      assert String.starts_with?(alias, "mat_")
      assert_receive :downloaded_history_media, 5_000
      assert_receive :model_consumed_history_media, 5_000
      assert Repo.get!(Message, capture.message_id).attachments == original.attachments
      :ok = ServerManager.stop_server(agent)
    end
  end
end
