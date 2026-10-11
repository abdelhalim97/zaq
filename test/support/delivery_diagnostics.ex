defmodule Zaq.TestSupport.DeliveryDiagnostics do
  @moduledoc """
  Bounded, failure-only evidence for real channel delivery acceptance tests.

  A separate OTP trace session coexists with the tests' native mailbox tracing.
  Only call identities, timings and error categories are retained; request bodies,
  credentials, SQL parameters and private execution outcomes are never reported.
  Database snapshots run in the failing test before its sandbox owner exits.
  """

  use GenServer

  import Ecto.Query

  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, TranscriptMessage}
  alias Zaq.Repo

  @limit 100
  @calls [
    {Zaq.Agent.StreamEvents, :consume, 3},
    {Zaq.Agent.HistorySync, :complete, 3},
    {Zaq.Agent.Factory, :apply_history_context, 3},
    {Zaq.Engine.Conversations, :finalize_incoming, 4},
    {Zaq.Channels.JidoChatBridge, :do_send_reply, 2},
    {Zaq.Channels.DeliveryConfirmation, :record, 3},
    {Zaq.Engine.HistoryIngress, :capture_confirmed, 1},
    {Zaq.Engine.HistoryIngress, :record_confirmation, 1},
    {Zaq.Engine.HistoryIngress, :associate_confirmation, 1}
  ]
  @events [
    [:zaq, :repo, :query],
    [:finch, :queue, :start],
    [:finch, :queue, :stop],
    [:finch, :queue, :exception]
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns bounded evidence without allowing a diagnostic error to mask the assertion."
  def snapshot(pid) do
    %{
      runtime: safely(fn -> GenServer.call(pid, :snapshot, 1_000) end),
      executions: safely(&executions/0),
      confirmations: safely(&confirmations/0),
      placements: safely(&placements/0)
    }
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    session = :trace.session_create(:delivery_diagnostics, self(), [])

    for {module, _, _} = mfa <- @calls do
      Code.ensure_loaded!(module)
      :trace.function(session, mfa, [{:_, [], [{:return_trace}, {:exception_trace}]}], [:local])
    end

    :trace.process(session, :all, true, [:call, :monotonic_timestamp])
    handler = {__MODULE__, self()}
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.observe/4, self())
    {:ok, %{session: session, handler: handler, recent: [], pending: %{}}}
  end

  @doc false
  def observe(event, measures, metadata, collector) do
    safe =
      metadata
      |> Map.take([:source, :name, :pool])
      |> Map.put(:result, category(metadata[:result] || metadata[:reason]))

    send(collector, {:observation, self(), event, measures, safe})
  end

  @impl true
  def handle_info({:trace_ts, pid, :call, {module, function, args}, at}, state) do
    key = {pid, {module, function, length(args)}}
    pending = Map.update(state.pending, key, [at], &[at | &1])
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:trace_ts, pid, kind, mfa, result, at}, state)
      when kind in [:return_from, :exception_from] do
    {starts, pending} = Map.pop(state.pending, {pid, mfa}, [])
    {started, rest} = List.pop_at(starts, 0)
    pending = if rest == [], do: pending, else: Map.put(pending, {pid, mfa}, rest)

    entry = %{
      pid: pid,
      call: mfa,
      event: kind,
      at_ms: milliseconds(at),
      duration_ms: if(started, do: milliseconds(at - started)),
      result: category(result)
    }

    {:noreply, retain(%{state | pending: pending}, entry)}
  end

  def handle_info({:observation, pid, event, measures, metadata}, state) do
    entry = %{
      pid: pid,
      event: event,
      at_ms: System.monotonic_time(:millisecond),
      metadata: metadata,
      timings_ms: Map.new(measures, fn {key, value} -> {key, milliseconds(value)} end)
    }

    pending = queue_pending(state.pending, pid, event, metadata)
    {:noreply, retain(%{state | pending: pending}, entry)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = System.monotonic_time()

    pending =
      state.pending
      |> Enum.take(@limit)
      |> Enum.map(fn {{pid, mfa}, starts} ->
        %{pid: pid, call: mfa, age_ms: milliseconds(now - List.last(starts))}
      end)

    processes =
      (Enum.map(pending, & &1.pid) ++ Enum.map(state.recent, & &1.pid))
      |> Enum.uniq()
      |> Enum.take(@limit)
      |> Map.new(&{&1, Process.info(&1, [:current_stacktrace, :message_queue_len, :status])})

    {:reply, %{pending: pending, processes: processes, recent: Enum.reverse(state.recent)}, state}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(state.handler)
    :trace.session_destroy(state.session)
  end

  defp retain(state, entry), do: %{state | recent: Enum.take([entry | state.recent], @limit)}

  defp queue_pending(pending, pid, [:finch, :queue, phase], metadata) do
    key = {pid, {:http_queue, metadata[:name], metadata[:pool]}}

    if phase == :start,
      do: Map.put(pending, key, [System.monotonic_time()]),
      else: Map.delete(pending, key)
  end

  defp queue_pending(pending, _pid, _event, _metadata), do: pending

  defp milliseconds(nil), do: nil
  defp milliseconds(value), do: System.convert_time_unit(value, :native, :millisecond)

  defp category({:ok, value}), do: {:ok, category(value)}
  defp category({:error, value}), do: {:error, category(value)}
  defp category(%{__struct__: module} = value), do: {module, category(Map.get(value, :reason))}

  defp category(value) when is_map(value),
    do: Map.take(value, [:confirmation, :history_capture, :history_capture_error])

  defp category(value) when is_atom(value), do: value
  defp category(_value), do: :other

  defp executions do
    Repo.all(
      from(e in ExecutionRecord,
        order_by: e.id,
        limit: @limit,
        select: map(e, [:id, :status, :root_execution_id, :public_answer_message_id])
      ),
      timeout: 1_000
    )
  end

  defp confirmations do
    Repo.all(
      from(m in Message,
        where: m.role == "assistant",
        order_by: m.id,
        limit: @limit,
        select: %{
          id: m.id,
          confirmation: fragment("?->'delivery_confirmation'", m.metadata),
          association: fragment("?->'history_association'", m.metadata)
        }
      ),
      timeout: 1_000
    )
  end

  defp placements do
    Repo.all(
      from(p in TranscriptMessage,
        order_by: p.id,
        limit: @limit,
        select: map(p, [:message_id, :transcript_id, :provenance])
      ),
      timeout: 1_000
    )
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:unavailable, error.__struct__}
  catch
    :exit, _ -> {:unavailable, :exit}
  end
end
