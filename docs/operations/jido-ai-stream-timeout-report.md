# ReAct stream timeout silently exhausts the worker without terminating the parent request

**Publication status (2026-10-10):** draft, not filed. Both GitHub CLI and the
configured GitHub integration rejected issue creation with HTTP 403
`Resource not accessible by personal access token`. Tracked in `zaq-emb.31.21`.
The suggested fix below is not implemented; bounded downstream validation does
not depend on fixing this deferred defect.

## Summary

When a ReAct event stream reaches its idle timeout before the provider responds,
`Runner.stream/3` can end normally without any terminal event. In the delegated
Agent path the worker becomes idle, while its parent still reports
`awaiting_llm` and the request remains pending. A late provider response cannot
repair the already-exhausted event stream.

This report is specifically about **missing terminal propagation after a real
timeout**, not about making the timeout longer or changing provider heartbeat
handling. It is distinct from #369/#370's late-event ordering after completion.
Related historical context: #195/#196 addressed stream liveness/timeout policy;
the explicit-timeout exhaustion path below still exists at the tested revision.

## Tested environment

- `jido_ai` 2.4.0 at `970575a89631d9be0cc0fa22d380ff1d211fa286`.
- Jido 2.4.0; ReqLLM 1.22.0; Bandit 1.12.5.
- Elixir 1.19.5, macOS, OTP 28.
- Real ReqLLM HTTP against a loopback OpenAI Responses-compatible SSE stub;
  no actual provider/API key, application database or membership logic.
- This is not a claim that a newer, untested main revision has the same result.

## Expected versus actual

Expected: timeout becomes a structured terminal failure for the original request,
allowing callers to finalize failure, stop waiting and release owned resources.

Actual Runner comparison (executed in a fresh, database-free VM):

```text
release_immediately (~203 ms):
  request_started, llm_started, llm_delta, llm_completed,
  checkpoint, checkpoint, request_completed
hold_beyond_timeout (~1,016 ms):
  request_started, llm_started
  Enumerable ends; no completed/failed/cancelled event and no raised timeout.
```

The same stub succeeds when released promptly; it is not matching/rejecting the
question text. The second case deliberately configures a 1-second native stream
timeout and a longer HTTP receive timeout.

Separately, a real configured-Agent walkthrough held its external model response
for about 160 seconds. Its native timeout was 75 seconds (15-second tool timeout
plus 60 seconds), versus a 120-second HTTP receive timeout. After release we
observed the parent request still pending/`awaiting_llm`; worker `idle`,
`runtime_task: nil`, `run_id: nil`, `last_error: nil`, `seq: 2`. The retained trace
contained only `request_started` and `llm_started`. Parent and worker mailboxes
were empty. The standalone parent harness is not presented as an independently
completed reproduction; the runnable minimal comparison below isolates Runner.

## Self-contained reproduction

Save as `react_timeout_repro.exs` and run in a project with the tested `jido_ai`,
ReqLLM and Bandit dependencies:

```sh
mix run --no-start react_timeout_repro.exs
```

The script starts only the required dependency applications, not the surrounding
application. It uses real HTTP and explicit barriers; no internal mocks or sleeps.

```elixir
defmodule ReActTimeoutStub do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    send(opts[:owner], {:model_http_waiting, self()})
    receive do
      :release_model -> :ok
    after
      5_000 -> raise "external barrier was not released"
    end

    request = Jason.decode!(body)
    delta = Jason.encode!(%{"delta" => "probe answer"})
    completed = Jason.encode!(%{"response" => %{
      "id" => "resp_probe", "model" => request["model"],
      "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
    }})
    conn
    |> put_resp_header("connection", "close")
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200,
      "event: response.output_text.delta\ndata: #{delta}\n\n" <>
      "event: response.completed\ndata: #{completed}\n\n")
  end
end

defmodule ReActTimeoutRepro do
  alias Jido.AI.Reasoning.ReAct.{Config, Runner}

  def run do
    for app <- [:jido_ai, :bandit], do: {:ok, _} = Application.ensure_all_started(app)
    {:ok, listener} = Supervisor.start_link([
      {Bandit, plug: {ReActTimeoutStub, owner: self()}, ip: {127, 0, 0, 1}, port: 0}
    ], strategy: :one_for_one)
    [{_, bandit, _, _}] = Supervisor.which_children(listener)
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    config = Config.new(%{
      model: "openai:gpt-4.1-mini", tools: [], stream_timeout_ms: 1_000,
      llm_opts: [base_url: "http://127.0.0.1:#{port}/v1",
        api_key: "local-only", receive_timeout: 5_000]
    })
    try do
      Enum.each([:release_immediately, :hold_beyond_timeout], &scenario(&1, config))
    after
      Supervisor.stop(listener)
    end
  end

  defp scenario(mode, config) do
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> Runner.stream("Any message", config) |> Enum.map(& &1.kind) end)
    http = receive do
      {:model_http_waiting, worker} -> worker
    after
      5_000 -> raise "model request did not reach loopback stub"
    end
    try do
      if mode == :release_immediately, do: send(http, :release_model)
      events = Task.await(task, 5_000)
      terminal? = Enum.any?(events, &(&1 in [:request_completed, :request_failed, :request_cancelled]))
      true = if mode == :release_immediately, do: terminal?, else: not terminal?
      IO.puts(Jason.encode!(%{mode: mode, events: events,
        terminal_event: terminal?, elapsed_ms: System.monotonic_time(:millisecond) - started}))
    after
      send(http, :release_model)
    end
  end
end

ReActTimeoutRepro.run()
```

## Source path explaining the observed state

At the tested revision:

1. [Runner timeout branch](https://github.com/agentjido/jido_ai/blob/970575a89631d9be0cc0fa22d380ff1d211fa286/lib/jido_ai/reasoning/react/runner.ex#L1366-L1390)
   returns `{:halt, %{state | done?: true}}` on `receive_timeout_ms`, without a
   terminal event. Cleanup cancels/stops the coordinator.
2. [Worker stream enumeration](https://github.com/agentjido/jido_ai/blob/970575a89631d9be0cc0fa22d380ff1d211fa286/lib/jido_ai/reasoning/react/worker/strategy.ex#L309-L326)
   sees ordinary enumerable exhaustion and sends `ai.react.worker.runtime.done`.
3. [Worker done handling](https://github.com/agentjido/jido_ai/blob/970575a89631d9be0cc0fa22d380ff1d211fa286/lib/jido_ai/reasoning/react/worker/strategy.ex#L267-L277)
   clears its active state but emits no parent failure. The parent never receives
   the terminal event needed to resolve its request.

## Suggested fix plan (proposal, not an implemented fix)

1. Pin failure first: a Runner timeout regression and a full parent/worker
   regression using an external held HTTP provider. Include prompt success,
   no-first-response starvation and mid-stream starvation.
2. Emit exactly one structured terminal timeout failure with the original
   request/run identity and valid monotonic sequence before stream cleanup.
   Distinguish timeout from normal completion and deliberate consumer halt/cancel.
3. Ensure worker exhaustion without a terminal event cannot leave its parent
   pending. Choose one synthesis owner so Runner and worker cannot duplicate
   failure events; preserve the existing ordered event-delivery contract.
4. Verify bounded coordinator/transport cleanup, ignored late responses and stale
   events, terminal status stability, no double notification, and next-request
   reuse. Preserve normal success and explicit cancellation behavior.
5. Document native-event-stream versus HTTP timeout relationships. Merely raising
   or disabling the timeout does not repair missing terminal propagation.

We are reporting this independently of our admission-time authorization feature;
there is no request here to weaken timeout semantics or introduce a new lifecycle
registry. No dependency fix has been applied downstream.
