# Self-contained upstream reproduction; no ZAQ modules, database or API credentials.
# With this repository's already-built dependencies:
# elixir -pa '_build/test-e2e/lib/*/ebin' test/repro/react_stream_timeout_upstream.exs
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

    completed =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_probe",
          "model" => request["model"],
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    conn
    |> put_resp_header("connection", "close")
    |> put_resp_content_type("text/event-stream")
    |> send_resp(
      200,
      "event: response.output_text.delta\ndata: #{delta}\n\nevent: response.completed\ndata: #{completed}\n\n"
    )
  end
end

defmodule ReActTimeoutRepro do
  alias Jido.AI.Reasoning.ReAct.{Config, Runner}

  def run do
    for app <- [:jido_ai, :bandit], do: {:ok, _} = Application.ensure_all_started(app)

    {:ok, listener} =
      Supervisor.start_link(
        [
          {Bandit, plug: {ReActTimeoutStub, owner: self()}, ip: {127, 0, 0, 1}, port: 0}
        ],
        strategy: :one_for_one
      )

    [{_, bandit, _, _}] = Supervisor.which_children(listener)
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    config =
      Config.new(%{
        model: "openai:gpt-4.1-mini",
        tools: [],
        stream_timeout_ms: 1_000,
        llm_opts: [
          base_url: "http://127.0.0.1:#{port}/v1",
          api_key: "local-only",
          receive_timeout: 5_000
        ]
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

    http =
      receive do
        {:model_http_waiting, worker} -> worker
      after
        5_000 -> raise "the model request did not reach the loopback stub"
      end

    try do
      if mode == :release_immediately, do: send(http, :release_model)
      events = Task.await(task, 5_000)

      terminal? =
        Enum.any?(events, &(&1 in [:request_completed, :request_failed, :request_cancelled]))

      true = if mode == :release_immediately, do: terminal?, else: not terminal?

      IO.puts(
        Jason.encode!(%{
          mode: mode,
          events: events,
          terminal_event: terminal?,
          elapsed_ms: System.monotonic_time(:millisecond) - started
        })
      )
    after
      send(http, :release_model)
    end
  end
end

ReActTimeoutRepro.run()
