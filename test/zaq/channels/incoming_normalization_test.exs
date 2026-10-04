defmodule Zaq.Channels.IncomingNormalizationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.JidoChatBridge.Incoming.{Discord, Mattermost, Telegram}

  test "Mattermost verifies room and provider channel type" do
    meta = %{chat_type: :public, is_dm: false, external_room_id: "room-1"}

    raw = %{
      "channel_type" => "O",
      "post" => %{"channel_id" => "room-1", "create_at" => 1_700_000_000_000}
    }

    assert {:ok, %{conversation_type: :room, source_scope: nil, provider_sent_at: %DateTime{}}} =
             Mattermost.normalize(meta, raw, nil)

    assert {:error, :unverified_communication_facts} =
             Mattermost.normalize(meta, put_in(raw, ["post", "channel_id"], "other"), nil)

    assert {:error, :unverified_communication_facts} =
             Mattermost.normalize(meta, %{raw | "channel_type" => "D"}, nil)
  end

  test "Telegram verifies chat type and emits a chat-local source namespace" do
    meta = %{chat_type: :private, is_dm: true, external_room_id: "-100123"}
    raw = %{"chat" => %{"id" => -100_123, "type" => "private"}, "date" => 1_700_000_000}

    assert {:ok,
            %{
              conversation_type: :one_to_one,
              source_scope: "-100123",
              provider_sent_at: %DateTime{}
            }} = Telegram.normalize(meta, raw, nil)

    assert {:error, :unverified_communication_facts} =
             Telegram.normalize(meta, put_in(raw, ["chat", "type"], "group"), nil)
  end

  test "Discord distinguishes guild, thread and verified direct-message evidence" do
    assert {:ok, %{conversation_type: :room}} =
             Discord.normalize(
               %{chat_type: :guild, is_dm: false, external_room_id: "channel-1"},
               %{guild_id: "guild-1", channel_id: "channel-1"},
               "2026-10-03T10:00:00Z"
             )

    assert {:ok, %{conversation_type: :room}} =
             Discord.normalize(
               %{chat_type: :thread, is_dm: false, external_room_id: "parent-1"},
               %{guild_id: "guild-1", channel_id: "thread-1", parent_id: "parent-1"},
               nil
             )

    assert {:ok, %{conversation_type: :one_to_one}} =
             Discord.normalize(
               %{chat_type: :dm, is_dm: true, external_room_id: "dm-1"},
               %{channel: %{id: "dm-1", type: 1}, channel_id: "dm-1", guild_id: nil},
               nil
             )

    assert {:error, :unverified_communication_facts} =
             Discord.normalize(
               %{chat_type: :dm, is_dm: true, external_room_id: "dm-1"},
               %{channel_id: "dm-1", guild_id: nil, type: 1},
               nil
             )
  end

  property "contradictory transport rooms never normalize to a known conversation" do
    check all(
            room <- string(:alphanumeric, min_length: 1, max_length: 30),
            other <- string(:alphanumeric, min_length: 1, max_length: 30),
            room != other
          ) do
      meta = %{chat_type: :group, is_dm: false, external_room_id: room}
      raw = %{chat: %{id: other, type: "group"}}
      assert {:error, :unverified_communication_facts} = Telegram.normalize(meta, raw, nil)
    end
  end
end
