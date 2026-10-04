defmodule Zaq.Engine.EmailConnectorSettingsTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.EmailConnectorSettings
  alias Zaq.Event
  alias Zaq.Types.EncryptedString

  defmodule RuntimeStub do
    def dispatch(event) do
      send(self(), {:runtime_sync, event})
      %{event | response: Process.get(:runtime_result, :ok)}
    end
  end

  defmodule UnavailableRuntimeRouter do
    def dispatch(_event), do: exit(:nodedown)
  end

  test "creates and updates only the explicitly selected SMTP connector" do
    assert {:ok, created} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Primary SMTP")
               },
               node_router: RuntimeStub
             )

    id = created.selected_config_id
    assert created.runtime == :synced

    assert_received {:runtime_sync,
                     %Event{
                       request: %{
                         config: %{
                           id: ^id,
                           provider: "email:smtp",
                           settings: %{"password" => "secret"}
                         }
                       },
                       opts: runtime_opts
                     }}

    assert runtime_opts[:confidential] == true
    assert Repo.get!(ChannelConfig, id).name == "Primary SMTP"

    other = insert_config("email:smtp", "Other SMTP")

    assert {:ok, updated} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: id,
                 params: smtp_params("Renamed SMTP")
               },
               node_router: RuntimeStub
             )

    assert updated.selected_config_id == id
    assert Repo.get!(ChannelConfig, id).name == "Renamed SMTP"
    assert Repo.get!(ChannelConfig, other.id).name == "Other SMTP"
    assert_received {:runtime_sync, %Event{request: %{config: %{id: ^id, name: "Renamed SMTP"}}}}
  end

  test "rejects wrong-provider, archived and stale connector selections" do
    smtp = insert_config("email:smtp", "SMTP")
    archived = insert_config("email:imap", "Archived IMAP")
    {:ok, _} = ChannelConfig.archive(archived)

    assert {:error, :connector_mismatch} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:imap",
                 selected_config_id: smtp.id,
                 params: %{}
               },
               node_router: RuntimeStub
             )

    assert {:error, :connector_mismatch} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:imap",
                 selected_config_id: archived.id,
                 params: %{}
               },
               node_router: RuntimeStub
             )
  end

  test "reports saved settings when runtime synchronization is pending" do
    Process.put(:runtime_result, {:error, :runtime_down})

    assert {:ok, %{selected_config_id: id, runtime: {:pending, :runtime_down}}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Pending SMTP")
               },
               node_router: RuntimeStub
             )

    assert Repo.get!(ChannelConfig, id).name == "Pending SMTP"
  end

  test "unreachable Channels does not undo saved configuration or expose runtime credentials" do
    assert {:ok, %{selected_config_id: id, runtime: {:pending, :channels_unavailable}}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Offline SMTP")
               },
               node_router: UnavailableRuntimeRouter
             )

    saved = Repo.get!(ChannelConfig, id)
    assert saved.name == "Offline SMTP"
    refute saved.settings["password"] == "secret"
    assert {:ok, "secret"} = EncryptedString.decrypt(saved.settings["password"])
  end

  test "enabled IMAP requires one exact live SMTP binding when selection is ambiguous" do
    first = insert_config("email:smtp", "First")
    _second = insert_config("email:smtp", "Second")

    params = %{
      "connector_name" => "Inbox",
      "enabled" => "true",
      "url" => "imap.example.com",
      "username" => "inbox@example.com",
      "password" => "secret",
      "selected_mailboxes" => ["INBOX"]
    }

    assert {:error, :missing_smtp_binding} =
             EmailConnectorSettings.save(
               %{provider: "email:imap", selected_config_id: :new, params: params},
               node_router: RuntimeStub
             )

    assert {:ok, %{selected_config_id: id}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:imap",
                 selected_config_id: :new,
                 params: Map.put(params, "smtp_config_id", to_string(first.id))
               },
               node_router: RuntimeStub
             )

    assert get_in(Repo.get!(ChannelConfig, id).settings, ["imap", "smtp_config_id"]) == first.id
    assert_received {:runtime_sync, %Event{request: %{config: %{id: ^id, token: "secret"}}}}
  end

  defp smtp_params(name) do
    %{
      "connector_name" => name,
      "enabled" => "false",
      "relay" => "smtp.example.com",
      "port" => "587",
      "transport_mode" => "starttls",
      "tls" => "enabled",
      "tls_verify" => "verify_peer",
      "from_email" => "noreply@example.com",
      "from_name" => "ZAQ",
      "password" => "secret"
    }
  end

  defp insert_config(provider, name) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: name,
      provider: provider,
      kind: "retrieval",
      enabled: provider != "email:imap",
      url: "https://example.invalid",
      token: "token",
      settings:
        if(provider == "email:imap",
          do: %{"imap" => %{"selected_mailboxes" => ["INBOX"], "smtp_config_id" => nil}},
          else: %{}
        )
    })
    |> Repo.insert!()
  end
end
