defmodule Zaq.Engine.Conversations.TokenUsageAggregatorTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo
  use ExUnitProperties

  @moduletag capture_log: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Conversation
  alias Zaq.Engine.Conversations.ExecutionRecord
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Conversations.TokenUsageAggregator
  alias Zaq.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  test "completed execution usage replaces message counters without counting failed records" do
    conv = create_conv_with_assistant_msg("gpt-4", 100, 50)
    answer = Repo.get_by!(Message, conversation_id: conv.id, role: "assistant")
    person = Repo.insert!(%Person{full_name: "Accounting owner"})
    assert {:ok, input} = Conversations.add_message(conv, %{role: "user", content: "Question"})

    assert {:ok, _} =
             %ExecutionRecord{}
             |> ExecutionRecord.changeset(%{
               person_id: person.id,
               user_message_id: input.id,
               public_answer_message_id: answer.id,
               status: "completed",
               finalization_token_hash: :crypto.hash(:sha256, "usage") |> Base.encode64(),
               usage: %{"prompt_tokens" => 7, "completion_tokens" => 3}
             })
             |> Repo.insert()

    assert {:ok, _} =
             Conversations.add_message(conv, %{
               role: "assistant",
               content: "Legacy",
               model: "gpt-4",
               prompt_tokens: 20,
               completion_tokens: 10
             })

    assert {:ok, failed_input} =
             Conversations.add_message(conv, %{role: "user", content: "Failed"})

    %ExecutionRecord{}
    |> ExecutionRecord.changeset(%{
      person_id: person.id,
      user_message_id: failed_input.id,
      status: "failed",
      finalization_token_hash: :crypto.hash(:sha256, "failed-usage") |> Base.encode64(),
      usage: %{"prompt_tokens" => 999, "completion_tokens" => 999}
    })
    |> Repo.insert!()

    assert :ok =
             perform_job(TokenUsageAggregator, %{"conversation_id" => conv.id, "model" => "gpt-4"})

    usage =
      Conversations.get_conversation!(conv.id).metadata["token_usage"][
        Date.to_iso8601(Date.utc_today())
      ]["gpt-4"]

    assert usage == %{"prompt_tokens" => 27, "completion_tokens" => 13, "total_tokens" => 40}

    assert :ok =
             perform_job(TokenUsageAggregator, %{"conversation_id" => conv.id, "model" => "gpt-4"})

    assert Conversations.get_conversation!(conv.id).metadata["token_usage"][
             Date.to_iso8601(Date.utc_today())
           ]["gpt-4"] == usage
  end

  defp create_conv_with_assistant_msg(model, prompt_tokens, completion_tokens) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "test_#{System.unique_integer([:positive])}"
      })

    {:ok, _msg} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: "Answer",
        model: model,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: prompt_tokens + completion_tokens
      })

    conv
  end

  property "coalesced accounting is retry-safe and equals the sum of persisted usage" do
    check all(
            usages <- list_of(tuple({integer(0..1_000), integer(0..1_000)}), max_length: 6),
            max_runs: 10
          ) do
      conv = create_conv_with_assistant_msg("gpt-4", 0, 0)

      for {prompt, completion} <- usages do
        assert {:ok, _} =
                 Conversations.add_message(conv, %{
                   role: "assistant",
                   content: "Answer",
                   model: "gpt-4",
                   prompt_tokens: prompt,
                   completion_tokens: completion
                 })
      end

      args = %{"conversation_id" => conv.id, "model" => "gpt-4"}
      assert :ok = perform_job(TokenUsageAggregator, args)
      first = Conversations.get_conversation!(conv.id).metadata
      assert :ok = perform_job(TokenUsageAggregator, args)
      assert Conversations.get_conversation!(conv.id).metadata == first

      expected =
        Enum.reduce(usages, 0, fn {prompt, completion}, total -> total + prompt + completion end)

      assert get_in(first, [
               "token_usage",
               Date.to_iso8601(Date.utc_today()),
               "gpt-4",
               "total_tokens"
             ]) == expected
    end
  end

  property "private root counters override individually while receipts never add usage" do
    check all(
            legacy_prompt <- integer(0..1_000),
            legacy_completion <- integer(0..1_000),
            private_prompt <- one_of([constant(nil), integer(0..1_000)]),
            private_completion <- one_of([constant(nil), integer(0..1_000)]),
            receipt_status <- member_of(~w(queued consumed unconsumed)),
            max_runs: 12
          ) do
      conv = create_conv_with_assistant_msg("gpt-4", legacy_prompt, legacy_completion)
      answer = Repo.get_by!(Message, conversation_id: conv.id, role: "assistant")
      owner = Repo.insert!(%Person{full_name: "Usage owner"})
      assert {:ok, input} = Conversations.add_message(conv, %{role: "user", content: "Root"})

      usage =
        %{"prompt_tokens" => private_prompt, "completion_tokens" => private_completion}
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      root =
        %ExecutionRecord{}
        |> ExecutionRecord.changeset(%{
          person_id: owner.id,
          user_message_id: input.id,
          public_answer_message_id: answer.id,
          status: "completed",
          finalization_token_hash: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode64(),
          usage: usage
        })
        |> Repo.insert!()

      assert {:ok, child} = Conversations.add_message(conv, %{role: "user", content: "Child"})

      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: owner.id,
        user_message_id: child.id,
        root_execution_id: root.id,
        status: receipt_status,
        finalization_token_hash: :crypto.hash(:sha256, Ecto.UUID.generate()) |> Base.encode64(),
        usage: %{"prompt_tokens" => 9_999, "completion_tokens" => 9_999}
      })
      |> Repo.insert!()

      args = %{"conversation_id" => conv.id, "model" => "gpt-4"}
      assert :ok = perform_job(TokenUsageAggregator, args)
      metadata = Conversations.get_conversation!(conv.id).metadata

      assert metadata["token_usage"][Date.to_iso8601(Date.utc_today())]["gpt-4"] ==
               %{
                 "prompt_tokens" => private_prompt || legacy_prompt,
                 "completion_tokens" => private_completion || legacy_completion,
                 "total_tokens" =>
                   (private_prompt || legacy_prompt) + (private_completion || legacy_completion)
               }

      assert :ok = perform_job(TokenUsageAggregator, args)
      assert Conversations.get_conversation!(conv.id).metadata == metadata
    end
  end

  test "accounting locks conversation metadata until the model totals are saved" do
    conv = create_conv_with_assistant_msg("gpt-4", 100, 50)

    assert {:ok, _} =
             Conversations.add_message(conv, %{
               role: "assistant",
               content: "Other model",
               model: "llama-3",
               prompt_tokens: 60,
               completion_tokens: 30
             })

    owner = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          :start ->
            perform_job(TokenUsageAggregator, %{"conversation_id" => conv.id, "model" => "gpt-4"})
        end
      end)

    Sandbox.allow(Repo, owner, task.pid)

    :telemetry.attach(
      ref,
      [:zaq, :repo, :query],
      &__MODULE__.pause_accounting_lock/4,
      {owner, task.pid, ref}
    )

    try do
      send(task.pid, :start)
      assert_receive {^ref, :locked}, 2_000

      other =
        Task.async(fn ->
          receive do
            :start ->
              send(owner, {ref, :other_started})

              perform_job(TokenUsageAggregator, %{
                "conversation_id" => conv.id,
                "model" => "llama-3"
              })
          end
        end)

      Sandbox.allow(Repo, owner, other.pid)
      send(other.pid, :start)
      assert_receive {^ref, :other_started}
      send(task.pid, {ref, :release})
      assert Task.await(task) == :ok
      assert Task.await(other) == :ok

      usage =
        Conversations.get_conversation!(conv.id).metadata["token_usage"][
          Date.to_iso8601(Date.utc_today())
        ]

      assert usage["gpt-4"]["total_tokens"] == 150
      assert usage["llama-3"]["total_tokens"] == 90
    after
      send(task.pid, {ref, :release})
      :telemetry.detach(ref)
    end
  end

  def pause_accounting_lock(_event, _measurements, metadata, {owner, writer, ref}) do
    if self() == writer and metadata.source == "conversations" and
         String.contains?(metadata.query, "FOR UPDATE") do
      send(owner, {ref, :locked})

      receive do
        {^ref, :release} -> :ok
      after
        5_000 -> raise "accounting lock was not released"
      end
    end
  end

  describe "perform/1" do
    test "returns and logs an error for an unparseable date without changing metadata" do
      conv = create_conv_with_assistant_msg("gpt-4", 100, 50)
      metadata_before = Conversations.get_conversation!(conv.id).metadata

      log =
        capture_log(fn ->
          send(
            self(),
            {:job_result,
             perform_job(TokenUsageAggregator, %{
               "conversation_id" => conv.id,
               "model" => "gpt-4",
               "date" => "not-a-date"
             })}
          )
        end)

      assert_receive {:job_result, {:error, reason}}
      assert reason != ""
      assert reason =~ "cannot parse \"not-a-date\" as date"
      assert log =~ "[TokenUsageAggregator] Failed for conversation #{conv.id}: #{reason}"
      assert Conversations.get_conversation!(conv.id).metadata == metadata_before
    end

    test "returns and logs an error when the conversation does not exist" do
      missing_id = Ecto.UUID.generate()

      assert Repo.get(Conversation, missing_id) == nil

      log =
        capture_log(fn ->
          send(
            self(),
            {:job_result,
             perform_job(TokenUsageAggregator, %{
               "conversation_id" => missing_id,
               "model" => "gpt-4",
               "date" => Date.to_iso8601(Date.utc_today())
             })}
          )
        end)

      assert_receive {:job_result, {:error, reason}}
      assert reason =~ "expected at least one result but got none"
      assert log =~ "[TokenUsageAggregator] Failed for conversation #{missing_id}: #{reason}"
    end

    test "pending accounting is coalesced but executing work never suppresses a new pass" do
      conv = create_conv_with_assistant_msg("gpt-4", 100, 50)

      assert {:ok, _} =
               Conversations.add_message(conv, %{
                 role: "assistant",
                 content: "Second",
                 model: "gpt-4",
                 prompt_tokens: 20,
                 completion_tokens: 10
               })

      assert [pending] = all_enqueued(worker: TokenUsageAggregator)
      assert pending.args["date"] == Date.to_iso8601(Date.utc_today())

      Repo.update_all(from(j in Oban.Job, where: j.id == ^pending.id), set: [state: "executing"])

      assert {:ok, _} =
               Conversations.add_message(conv, %{
                 role: "assistant",
                 content: "Arrived during execution",
                 model: "gpt-4",
                 prompt_tokens: 30,
                 completion_tokens: 15
               })

      assert [_new_pass] = all_enqueued(worker: TokenUsageAggregator)
      assert :ok = perform_job(TokenUsageAggregator, pending.args)
      today = pending.args["date"]

      assert get_in(Conversations.get_conversation!(conv.id).metadata, [
               "token_usage",
               today,
               "gpt-4",
               "total_tokens"
             ]) == 225
    end

    test "a delayed job accounts for its message date rather than the execution date" do
      conv = create_conv_with_assistant_msg("gpt-4", 70, 30)
      yesterday = Date.add(Date.utc_today(), -1)
      timestamp = DateTime.new!(yesterday, ~T[23:59:59.999999], "Etc/UTC")

      Repo.update_all(from(m in Message, where: m.conversation_id == ^conv.id),
        set: [inserted_at: timestamp]
      )

      assert :ok =
               perform_job(TokenUsageAggregator, %{
                 "conversation_id" => conv.id,
                 "model" => "gpt-4",
                 "date" => Date.to_iso8601(yesterday)
               })

      usage = Conversations.get_conversation!(conv.id).metadata["token_usage"]
      assert usage[Date.to_iso8601(yesterday)]["gpt-4"]["total_tokens"] == 100
      refute Map.has_key?(usage, Date.to_iso8601(Date.utc_today()))
    end

    test "aggregates token usage into conversation metadata" do
      conv = create_conv_with_assistant_msg("gpt-4", 100, 50)

      assert :ok =
               perform_job(TokenUsageAggregator, %{
                 "conversation_id" => conv.id,
                 "model" => "gpt-4"
               })

      updated = Conversations.get_conversation!(conv.id)
      today = Date.utc_today() |> Date.to_iso8601()
      usage = get_in(updated.metadata, ["token_usage", today, "gpt-4"])

      assert usage["prompt_tokens"] == 100
      assert usage["completion_tokens"] == 50
      assert usage["total_tokens"] == 150
    end

    test "idempotency — running twice accumulates the same totals" do
      conv = create_conv_with_assistant_msg("gpt-4", 200, 100)

      job_args = %{"conversation_id" => conv.id, "model" => "gpt-4"}

      assert :ok = perform_job(TokenUsageAggregator, job_args)
      assert :ok = perform_job(TokenUsageAggregator, job_args)

      updated = Conversations.get_conversation!(conv.id)
      today = Date.utc_today() |> Date.to_iso8601()
      usage = get_in(updated.metadata, ["token_usage", today, "gpt-4"])

      # Should reflect actual DB totals (200+100), not doubled
      assert usage["prompt_tokens"] == 200
      assert usage["completion_tokens"] == 100
    end

    test "multiple models aggregated independently" do
      {:ok, conv} =
        Conversations.create_conversation(%{
          channel_type: "bo",
          channel_user_id: "multi_model_#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Conversations.add_message(conv, %{
          role: "assistant",
          content: "GPT answer",
          model: "gpt-4",
          prompt_tokens: 80,
          completion_tokens: 40
        })

      {:ok, _} =
        Conversations.add_message(conv, %{
          role: "assistant",
          content: "Llama answer",
          model: "llama-3",
          prompt_tokens: 60,
          completion_tokens: 30
        })

      assert :ok =
               perform_job(TokenUsageAggregator, %{
                 "conversation_id" => conv.id,
                 "model" => "gpt-4"
               })

      assert :ok =
               perform_job(TokenUsageAggregator, %{
                 "conversation_id" => conv.id,
                 "model" => "llama-3"
               })

      updated = Conversations.get_conversation!(conv.id)
      today = Date.utc_today() |> Date.to_iso8601()

      gpt_usage = get_in(updated.metadata, ["token_usage", today, "gpt-4"])
      llama_usage = get_in(updated.metadata, ["token_usage", today, "llama-3"])

      assert gpt_usage["prompt_tokens"] == 80
      assert llama_usage["prompt_tokens"] == 60
    end
  end
end
