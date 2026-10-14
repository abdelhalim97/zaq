defmodule Zaq.Engine.Notifications.EmailThreadingTest do
  @moduledoc """
  Outbound email threading through the real seam: `Notifications` resolves the
  opaque anchor and passes it down; the real `EmailBridge` mints the Message-ID,
  builds the RFC headers, and returns the delivery receipt; the engine surfaces
  the receipt on `:sent` only.

  Only the SMTP boundary is stubbed — the notification travels through
  `Channels.Api` and `EmailBridge.send_reply` exactly as in production, so these
  tests observe the headers the recipient's mail client would actually see.
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import Zaq.CommunicationFixtures

  alias Zaq.Accounts.{People, Person, PersonChannel, PersonIdentities}
  alias Zaq.Channels.AgentRouting
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Engine.PeopleGateway
  alias Zaq.Ingestion.{Document, ExternalPermissions}
  alias Zaq.Repo

  # ── Stubs ──────────────────────────────────────────────────────────

  defmodule StubNodeRouter do
    def dispatch(event) do
      api_module = Keyword.get(event.opts, :channels_api_module, Zaq.Channels.Api)
      action = Keyword.get(event.opts, :action, :invoke)
      if action == :deliver_outgoing, do: send(self(), {:outgoing, event.request})

      api_module =
        if action == :bridge_available,
          do: Zaq.Engine.Notifications.EmailThreadingTest.AlwaysAvailableChannelsApi,
          else: api_module

      api_module.handle_event(event, action, nil)
    end
  end

  defmodule AlwaysAvailableChannelsApi do
    alias Zaq.Channels.Api

    def handle_event(event, :bridge_available, _context), do: %{event | response: true}
    def handle_event(event, action, context), do: Api.handle_event(event, action, context)
  end

  # Routes delivery to the REAL EmailBridge — the hop under test.
  defmodule RealEmailBridgeRouter do
    alias Zaq.Channels.Bridge
    def bridge_for(_provider), do: Zaq.Channels.EmailBridge
    def fetch_connection_details(_provider), do: %{}

    def fetch_channel_config(provider, id),
      do: Bridge.fetch_channel_config(provider, id)

    def fetch_connection_details_for_config(_config), do: %{}
  end

  # SMTP boundary stubs — the only stubbed hop.
  defmodule CapturingSmtp do
    def send_notification(recipient, payload, metadata, id) do
      send(self(), {:smtp_connector, id})
      send_notification(recipient, payload, metadata)
    end

    def send_notification(recipient, payload, _metadata) do
      send(self(), {:smtp, recipient, payload})
      :ok
    end
  end

  defmodule FailingSmtp do
    def send_notification(recipient, payload, metadata, _id),
      do: send_notification(recipient, payload, metadata)

    def send_notification(_recipient, _payload, _metadata), do: {:error, :smtp_down}
  end

  # Chat-channel stub: a bridge without receipts, returning bare `:ok`.
  defmodule CapturingChatBridge do
    alias Zaq.Channels.Bridge

    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}
    def fetch_connection_details_for_config(_config), do: %{}
    def fetch_channel_config(provider), do: Bridge.fetch_channel_config(provider)
    def fetch_channel_config(provider, id), do: Bridge.fetch_channel_config(provider, id)

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing})
      :ok
    end
  end

  # ── Fixtures ───────────────────────────────────────────────────────

  defp smtp_config(settings \\ %{"from_email" => "bot@acme.test"}) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Email-#{System.unique_integer([:positive])}",
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp://localhost",
      token: "test-token",
      enabled: true,
      settings: settings
    })
    |> Repo.insert!()
  end

  defp person_with_email do
    {:ok, person} =
      People.create_person(%{full_name: "Lead #{System.unique_integer([:positive])}"})

    person_channel_fixture(%{
      person_id: person.id,
      platform: "email",
      channel_identifier: "lead-#{System.unique_integer([:positive])}@example.test",
      weight: 1
    })

    person
  end

  # A prior send as the write path stores it today: the channel-agnostic anchor.
  defp seed_prior_send(person, topic, message_id, references) do
    seed_prior_message(person, topic, %{
      "topic" => topic,
      "threading" => %{
        "anchor" => %{
          "message_id" => message_id,
          "thread_id" => List.first(references) || message_id,
          "references" => references
        }
      }
    })
  end

  defp seed_prior_message(person, topic, metadata) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "email:imap",
        channel_user_id: topic,
        person_id: person.id
      })

    {:ok, _msg} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: "prior send",
        metadata: metadata
      })

    conv
  end

  defp notify(person, subject, opts \\ []) do
    bridge = Keyword.get(opts, :bridge, RealEmailBridgeRouter)

    Notifications.notify_person(
      person.id,
      %{subject: subject, message: "hello"},
      channels_event_opts: [bridge_module: bridge]
    )
  end

  defp captured_headers do
    receive do
      {:smtp, _recipient, payload} -> payload["headers"]
    after
      0 -> flunk("no SMTP delivery captured")
    end
  end

  setup do
    Application.put_env(:zaq, :notifications_node_router_module, StubNodeRouter)
    Application.put_env(:zaq, :email_bridge_smtp_module, CapturingSmtp)

    on_exit(fn ->
      Application.delete_env(:zaq, :notifications_node_router_module)
      Application.delete_env(:zaq, :email_bridge_smtp_module)
    end)

    from(c in ChannelConfig, where: c.provider == "email:smtp") |> Repo.delete_all()
    smtp_config()

    :ok
  end

  # ── First send: mint only, no anchor ───────────────────────────────

  test "an imported ACL email receives a notification through its creation-time default link" do
    sender = Repo.get_by!(ChannelConfig, provider: "email:smtp")
    {:ok, _} = ChannelConfig.set_default_smtp_connector(sender.id)

    {:ok, document} =
      Document.upsert(%{source: "acl-notification/#{System.unique_integer([:positive])}.md"})

    record = %Record{
      id: "file",
      kind: :file,
      attributes: %{provider: "google_drive"},
      permissions: [%{email: "acl@example.test", display_name: "ACL contact"}]
    }

    assert :ok = ExternalPermissions.apply(record, [document])
    assert {:ok, person} = People.match_person(%{email: "acl@example.test"})
    assert [%{platform: "email", channel_config_id: id}] = People.list_person_channels(person.id)
    assert id == sender.id
    assert {:ok, %{status: :sent, channel: "email"}} = notify(person, "ACL notification")

    assert_received {:outgoing,
                     %Outgoing{provider: "email", routing_context: %{channel_config_id: ^id}}}

    assert_received {:smtp_connector, ^id}
    assert_received {:smtp, "acl@example.test", _}
  end

  test "profile lifecycle binds while disabled, preserves old links and delivers through their selected sender" do
    sender = Repo.get_by!(ChannelConfig, provider: "email:smtp")
    sender = sender |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    # Config selection must not require an available or running communication bridge.
    previous = Application.get_env(:zaq, :channels)

    person =
      try do
        Application.put_env(:zaq, :channels, %{})

        assert {:ok, person} =
                 People.create_person(%{full_name: "Contact", email: " First@Example.test "})

        person
      after
        Application.put_env(:zaq, :channels, previous)
      end

    assert [first] = People.list_person_channels(person.id)
    assert first.channel_identifier == "first@example.test"
    assert first.channel_config_id == sender.id

    assert {:error, :connector_mismatch} =
             People.find_or_create_from_channel("email", %{
               channel_id: "invalid-origin@example.test",
               email: "invalid-origin@example.test",
               channel_config_id: -1
             })

    refute Repo.get_by(Person, email: "invalid-origin@example.test")
    refute Repo.get_by(PersonChannel, channel_identifier: "invalid-origin@example.test")
    assert {:ok, owner} = PersonIdentities.lookup("email", %{"channel_id" => person.email})
    assert owner.id == person.id
    assert {:ok, %{status: :skipped}} = notify(person, "Disabled")
    refute_received {:smtp, _, _}

    assert [%{incoming?: false}] = ChannelConfig.list_person_channel_targets("email", sender.id)
    assert ChannelConfig.list_incoming_routing_configs_for_platform("email") == []

    assert {:error, _} =
             PeopleGateway.dispatch(:update_channel, %{
               id: first.id,
               attrs: %{},
               rules: [AgentRouting.rule_attrs(%{channel_config_id: sender.id}, :none)]
             })

    assert IncomingMessageRouting.get_rule(%{person_id: person.id, channel_config_id: sender.id}) ==
             nil

    sender |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
    assert {:ok, _} = ChannelConfig.set_default_smtp_connector(sender.id)
    second = smtp_config(%{"from_email" => "other@acme.test"})
    assert {:ok, _} = ChannelConfig.set_default_smtp_connector(second.id)

    assert {:ok, person} =
             People.update_person(person, %{full_name: "Renamed", email: " FIRST@example.test "})

    assert [^first] = People.list_person_channels(person.id)
    assert {:ok, %{status: :sent, channel: "email"}} = notify(person, "Original sender")
    assert_received {:smtp_connector, id}
    assert id == sender.id
    assert_received {:smtp, "first@example.test", _}

    assert {:ok, person} = People.update_person(person, %{email: "second@example.test"})
    assert [^first, next] = People.list_person_channels(person.id)
    assert next.channel_config_id == second.id
    assert {:ok, _} = People.update_person(person, %{email: "second@example.test"})
    assert [^first, ^next] = People.list_person_channels(person.id)
    assert {:ok, other} = People.create_person(%{full_name: "Later"})
    assert {:ok, other} = People.update_person(other, %{email: "later@example.test"})
    assert [%{channel_config_id: new_id}] = People.list_person_channels(other.id)
    assert new_id == second.id
    assert {:ok, %{status: :sent}} = notify(other, "New sender")
    assert_received {:smtp_connector, ^new_id}
    assert_received {:smtp, "later@example.test", _}
  end

  for state <- [:missing, :ambiguous, :archived] do
    @tag default_state: state
    test "#{state} default selection rolls back profile, identity and link writes", %{
      default_state: state
    } do
      sender = Repo.get_by!(ChannelConfig, provider: "email:smtp")

      case state do
        :missing ->
          Repo.delete!(sender)

        :ambiguous ->
          Repo.update_all(ChannelConfig, set: [notification_default: false])
          smtp_config()

        :archived ->
          assert {:ok, _} = ChannelConfig.set_default_smtp_connector(sender.id)

          sender
          |> Ecto.Changeset.change(
            enabled: false,
            archived_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )
          |> Repo.update!()

          smtp_config()
      end

      email = "#{state}@example.test"
      assert {:error, changeset} = People.create_person(%{full_name: "Unavailable", email: email})
      assert errors_on(changeset).email != []
      refute Repo.get_by(Person, email: email)
      refute Repo.get_by(PersonChannel, channel_identifier: email)
      assert {:error, :not_found} = PersonIdentities.lookup("email", %{"channel_id" => email})
    end
  end

  test "application email and origin scope survive sending and logging" do
    sender = Repo.get_by!(ChannelConfig, provider: "email:smtp")

    inbox =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Bound inbox",
        provider: "email:imap",
        kind: "retrieval",
        enabled: true,
        url: "imap://localhost",
        token: "test-token",
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"], "smtp_config_id" => sender.id}}
      })
      |> Repo.insert!()

    assert {:ok, person} =
             People.find_or_create_from_channel("email", %{
               channel_id: "scoped@example.test",
               email: "scoped@example.test",
               channel_config_id: inbox.id
             })

    assert [%{channel_config_id: inbox_id}] = People.list_person_channels(person.id)
    assert inbox_id == inbox.id

    assert {:ok, %{status: :sent, channel: "email", notification_log_id: log_id}} =
             notify(person, "Scoped send")

    assert_received {:outgoing,
                     %Outgoing{
                       provider: "email",
                       routing_context: %{channel_config_id: origin_id}
                     }}

    assert origin_id == inbox.id
    assert_received {:smtp_connector, smtp_id}
    assert smtp_id == sender.id
    log = Repo.get!(NotificationLog, log_id)

    assert [%{"platform" => "email", "identifier" => "scoped@example.test", "status" => "ok"}] =
             log.channels_tried
  end

  describe "first send (no anchor)" do
    test "mints a Message-ID, sets no In-Reply-To, and is its own thread root" do
      person = person_with_email()

      assert {:ok, result} = notify(person, "Topic A")
      headers = captured_headers()

      assert headers["Message-ID"] =~ ~r/^<zaq-[0-9a-f-]{36}@acme\.test>$/
      refute Map.has_key?(headers, "In-Reply-To")
      refute Map.has_key?(headers, "References")

      # Generic threading fields surfaced on the result, matching the wire.
      assert result.status == :sent
      assert headers["Message-ID"] == "<#{result.message_id}>"
      # First send is the root of its own thread.
      assert result.thread_id == result.message_id
      assert result.thread_metadata["threading"]["anchor"]["references"] == []
    end

    test "falls back to the default domain when no SMTP from_email is configured" do
      from(c in ChannelConfig, where: c.provider == "email:smtp") |> Repo.delete_all()
      smtp_config(%{})
      person = person_with_email()

      assert {:ok, result} = notify(person, "Topic A")

      assert result.message_id =~ ~r/@zaq\.local$/
    end
  end

  # ── Follow-up send: chains onto the anchor ─────────────────────────

  describe "follow-up send (anchor present)" do
    test "points In-Reply-To at the prior Message-ID and extends the references chain" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m1@acme.test", [])

      assert {:ok, result} = notify(person, "Topic A")
      headers = captured_headers()

      # In-Reply-To points at the prior send; References = prior chain ++ [parent].
      assert headers["In-Reply-To"] == "<m1@acme.test>"
      assert headers["References"] == "<m1@acme.test>"
      # One-message thread → the prior message is the root.
      assert result.thread_id == "m1@acme.test"

      # This send mints its own fresh id, distinct from the parent.
      refute result.message_id == "m1@acme.test"
      assert headers["Message-ID"] == "<#{result.message_id}>"
    end

    test "carries the existing root and appends the parent to a longer chain" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m2@acme.test", ["m0@acme.test", "m1@acme.test"])

      assert {:ok, result} = notify(person, "Topic A")
      headers = captured_headers()

      assert headers["In-Reply-To"] == "<m2@acme.test>"
      assert headers["References"] == "<m0@acme.test> <m1@acme.test> <m2@acme.test>"

      # Root stays the head of the chain.
      assert result.thread_id == "m0@acme.test"
    end

    test "does not chain onto another person's send under the same topic" do
      lead_a = person_with_email()
      lead_b = person_with_email()
      seed_prior_send(lead_a, "Topic A", "a1@acme.test", [])

      assert {:ok, _result} = notify(lead_b, "Topic A")
      headers = captured_headers()

      refute Map.has_key?(headers, "In-Reply-To")
    end
  end

  # ── Grouping guard ─────────────────────────────────────────────────

  describe "grouping guard" do
    # Writing a thread_key would re-key the conversation to the minted id, and
    # the next topic/subject lookup would miss it — breaking the chain.
    test "the surfaced thread_metadata never carries a thread_key or email residue" do
      person = person_with_email()

      assert {:ok, result} = notify(person, "Topic A")

      refute Map.has_key?(result.thread_metadata, "email")
      refute Map.has_key?(result.thread_metadata["threading"]["anchor"], "thread_key")
    end
  end

  # ── Store-only-on-success (Bug #3) ─────────────────────────────────

  describe "store-only-on-success (Bug #3)" do
    test "surfaces no threading when delivery fails on every channel" do
      Application.put_env(:zaq, :email_bridge_smtp_module, FailingSmtp)
      person = person_with_email()

      assert {:error, failed} = notify(person, "Topic A")

      assert failed.status == :failed
      refute Map.has_key?(failed, :message_id)
      refute Map.has_key?(failed, :thread_id)
      refute Map.has_key?(failed, :thread_metadata)
    end

    test "a failed send leaves no anchor for the next send" do
      Application.put_env(:zaq, :email_bridge_smtp_module, FailingSmtp)
      person = person_with_email()

      assert {:error, _} = notify(person, "Topic A")

      # Nothing was persisted, so the anchor lookup still finds nothing.
      assert Conversations.latest_thread_anchor(person.id, "email:imap", "Topic A") == nil
    end

    test "surfaces no threading on a skipped notification" do
      {:ok, person} = People.create_person(%{full_name: "No Channels"})

      assert {:ok, result} = Notifications.notify_person(person.id, %{subject: "T", message: "b"})

      assert result.status == :skipped
      refute Map.has_key?(result, :message_id)
      refute Map.has_key?(result, :thread_metadata)
    end
  end

  # ── Non-email channels untouched ───────────────────────────────────

  describe "non-email channels" do
    test "a chat notification gets no anchor, no receipt fields, no email metadata" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "MM-#{System.unique_integer([:positive])}",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://mm.test",
        token: "t",
        enabled: true
      })
      |> Repo.insert!()

      {:ok, person} = People.create_person(%{full_name: "Chat Person"})

      person_channel_fixture(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "U123",
        weight: 1
      })

      assert {:ok, result} = notify(person, "Topic A", bridge: CapturingChatBridge)

      assert_receive {:delivered, %Outgoing{} = outgoing}
      refute Map.has_key?(outgoing.metadata, "email")
      assert outgoing.thread_anchor == nil
      assert outgoing.in_reply_to == nil
      refute Map.has_key?(result, :message_id)
    end
  end
end
