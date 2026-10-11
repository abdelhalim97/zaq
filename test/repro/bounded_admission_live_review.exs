# Manual review, not a browser E2E spec. Run against the existing isolated demo:
# elixir --hidden --sname admission_review -pa '_build/test-e2e/lib/*/ebin' \
#   test/repro/bounded_admission_live_review.exs
# Creates a fresh connector/Person; never resets the earlier stuck execution.
defmodule Zaq.Repro.BoundedAdmissionLiveReview do
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, Transcript}
  alias Zaq.Repo
  alias Zaq.Repro.AdmissionLiveDemo

  @answer "The input was admitted before access loss. Its answer completes normally."

  def run do
    {:ok, hostname} = :inet.gethostname()
    :inet_db.add_host({127, 0, 0, 1}, [hostname])
    :inet_db.set_lookup([:file])
    target = String.to_atom("zaq_admission_demo@#{hostname}")
    true = Node.connect(target)
    original = rpc(target, AdmissionLiveDemo, :step, [:state])

    source = File.read!("test/repro/admission_live_demo.exs")
    {offset, _} = :binary.match(source, "\n{:ok, _} = Zaq.Repro.AdmissionLiveDemo.start_link()")
    module_source = binary_part(source, 0, offset)
    rpc(target, Code, :compile_string, [module_source])
    label = "Bounded admission review #{System.system_time(:millisecond)}"

    {:ok, demo} =
      rpc(target, GenServer, :start, [AdmissionLiveDemo, [observer: self(), label: label], []])

    state = rpc(target, :sys, :get_state, [demo])
    :submitted = rpc(target, GenServer, :call, [demo, :start])

    http =
      receive do
        {:demo_model_waiting, worker} -> worker
      after
        5_000 -> raise "admitted model request never reached the external stub"
      end

    held_at = System.monotonic_time(:millisecond)

    try do
      root = execution(target, state.config.id, "root")
      true = root.status == "pending" and not is_nil(root.admitted_at)
      transcript = rpc(target, Repo, :get_by!, [Transcript, [channel_config_id: state.config.id]])
      server_id = "#{state.agent.name}:history:#{transcript.id}:person:#{state.person.id}"
      ledger = rpc(target, :sys, :get_state, [ServerManager]).history[server_id]
      monitor = Process.monitor(ledger.pid)
      {:ok, native} = rpc(target, Jido.AgentServer, :status, [ledger.pid])
      true = native.raw_state.__strategy__.status == :awaiting_llm

      %{read_access: false} = rpc(target, GenServer, :call, [demo, :revoke])
      :submitted = rpc(target, GenServer, :call, [demo, :new_input])
      denied = await_denial(target, state.config.id, System.monotonic_time(:millisecond) + 5_000)
      true = is_nil(denied.admitted_at) and is_nil(denied.public_answer_message_id)
      held_ms = System.monotonic_time(:millisecond) - held_at
      true = held_ms < 5_000
      :ok = rpc(target, GenServer, :call, [demo, :release])

      delivered =
        receive do
          {:history_post, %{"message" => @answer} = payload} -> payload
          {:history_update, %{"message" => @answer} = payload} -> payload
        after
          5_000 -> raise "accepted terminal answer was not delivered to the external provider"
        end

      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        5_000 -> raise "the exact runtime did not retire after accepted completion"
      end

      completed = execution(target, state.config.id, "root")
      true = completed.status == "completed" and completed.admitted_at == root.admitted_at
      answer = rpc(target, Repo, :get!, [Message, completed.public_answer_message_id])
      true = answer.content == @answer
      true = completed.person_id == state.person.id
      true = answer.metadata["in_reply_to_message_id"] == root.user_message_id
      false = Map.has_key?(rpc(target, :sys, :get_state, [ServerManager]).history, server_id)
      true = original == rpc(target, AdmissionLiveDemo, :step, [:state])

      result = %{
        outcome: :passed,
        barrier_ms: held_ms,
        accepted: completed.status,
        denied: denied.status,
        denied_admitted: false,
        answer: answer.content,
        provider_delivery: if(delivered["message"] == @answer, do: "confirmed"),
        exact_runtime_retired: true,
        original_stuck_request_untouched: true,
        transcript_id: transcript.id,
        root_message_id: root.user_message_id,
        denied_message_id: denied.user_message_id
      }

      IO.puts(Jason.encode!(result))
    after
      send(http, :release_demo_model)
    end
  end

  defp execution(target, config_id, suffix) do
    case rpc(target, Repo, :get_by, [
           Message,
           [external_message_id: "admission-demo-#{suffix}-#{config_id}"]
         ]) do
      nil -> nil
      message -> rpc(target, Repo, :get_by, [ExecutionRecord, [user_message_id: message.id]])
    end
  end

  defp await_denial(target, config_id, deadline) do
    case execution(target, config_id, "denied") do
      %{status: "failed"} = denied ->
        denied

      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: raise("new input was not denied")

        receive do
        after
          10 -> :ok
        end

        await_denial(target, config_id, deadline)
    end
  end

  defp rpc(target, module, function, args) do
    case :rpc.call(target, module, function, args, 5_000) do
      {:badrpc, reason} -> raise "demo RPC failed: #{inspect(reason)}"
      result -> result
    end
  end
end

Zaq.Repro.BoundedAdmissionLiveReview.run()
