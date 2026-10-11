defmodule Zaq.Agent.HistoryLifecycle do
  @moduledoc """
  ServerManager's internal history-context ledger and admission lease transitions.

  Cursors describe incorporated context, never an individual model projection.
  One exact runtime incarnation and calling process own each lease. Completion
  verifies native context application before publishing cursors to the next
  waiter. Engine owns admission/content authorization; this module reads no
  storage and exposes no agent Action or tool.
  """

  alias Zaq.Agent.Factory

  @doc "Validates an optional initial incorporated cursor vector; nil denotes a legacy runtime."
  def validate_initial(nil), do: :ok

  def validate_initial(cursors),
    do: if(valid_cursors?(cursors), do: :ok, else: {:error, :invalid_history_cursor})

  @doc "Initializes one incarnation, disposing any replaced lease and its waiting admissions."
  def initialize(history, server_id, pid, cursors, principal \\ nil) do
    history = drop(history, server_id)

    if is_nil(cursors),
      do: history,
      else:
        Map.put(history, server_id, %{
          pid: pid,
          principal: principal,
          cursors: cursors,
          pins: %{},
          retirement: nil,
          lease: nil,
          waiters: []
        })
  end

  @doc "Grants a process-owned lease, or defers another caller without advancing its cursor."
  def begin_request(history, server_id, pid, from, opts \\ []) do
    if deadline_expired?(opts[:deadline]) do
      {:reply, {:error, :history_handoff_timeout}, history}
    else
      admit_request(history, server_id, pid, from, opts)
    end
  end

  defp admit_request(history, server_id, pid, from, opts) do
    case Map.get(history, server_id) do
      %{pid: ^pid, lease: nil} = entry ->
        {entry, lease} = grant(entry, from, opts)
        {:reply, {:ok, lease}, Map.put(history, server_id, entry)}

      %{pid: ^pid, lease: %{owner: owner}} when elem(from, 0) == owner ->
        {:reply, {:error, :history_request_active}, history}

      %{pid: ^pid} = entry ->
        waiter = %{
          from: from,
          id: make_ref(),
          deadline: opts[:deadline],
          input_id: opts[:input_id],
          reservation?: opts[:reservation?] == true,
          server_id: server_id,
          monitor: Process.monitor(elem(from, 0))
        }

        schedule_expiry(waiter)
        {:wait, Map.put(history, server_id, %{entry | waiters: entry.waiters ++ [waiter]})}

      _ ->
        {:reply, {:error, :missing_history_cursor}, history}
    end
  end

  @doc "Confirms native context application before committing cursors and releasing the next caller."
  def complete(history, server_id, token, context, cursors, owner) do
    with {:ok, entry} <- owned_entry(history, server_id, token, owner),
         :ok <- validate_next(entry.cursors, cursors),
         :ok <- Factory.apply_history_context(entry.pid, context, entry.lease.op_id) do
      Process.demonitor(entry.lease.monitor, [:flush])
      entry = advance_waiter(%{entry | cursors: cursors, lease: nil})
      {:ok, Map.put(history, server_id, entry)}
    else
      {:error, reason}
      when reason in [:invalid_history_cursor, :lease_owner_mismatch, :stale_history_lease] ->
        {:error, reason}

      {:error, reason} ->
        {:invalidate, reason}
    end
  end

  @doc "Checks exact lease-token and calling-process ownership without altering lifecycle state."
  def owned_entry(history, server_id, token, owner) do
    case Map.get(history, server_id) do
      %{lease: %{token: ^token, owner: ^owner}} = entry -> {:ok, entry}
      %{lease: %{token: ^token}} -> {:error, :lease_owner_mismatch}
      _ -> {:error, :stale_history_lease}
    end
  end

  @doc "Finds the runtime scope owned by a terminated lease-monitor reference."
  def owner_scope(history, ref) do
    Enum.find_value(history, fn
      {server_id, %{lease: %{monitor: ^ref}}} -> server_id
      _ -> nil
    end)
  end

  @doc "Disposes one incarnation's ledger and rejects its queued callers as stale."
  def drop(history, server_id, reason \\ :stale_runtime) do
    case Map.get(history, server_id) do
      nil ->
        :ok

      entry ->
        if entry.lease, do: Process.demonitor(entry.lease.monitor, [:flush])
        Enum.each(entry.pins, fn {_key, monitor} -> Process.demonitor(monitor, [:flush]) end)
        Enum.each(entry.waiters, &discard_waiter(&1, reason))
    end

    Map.delete(history, server_id)
  end

  defp grant(entry, {owner, _tag}, opts) do
    lease = %{
      token: make_ref(),
      owner: owner,
      monitor: Process.monitor(owner),
      op_id: Jido.Util.generate_id(),
      pid: entry.pid,
      cursors: entry.cursors,
      input_id: opts[:input_id]
    }

    {%{entry | lease: lease}, Map.take(lease, [:token, :op_id, :pid, :cursors])}
  end

  @doc "Pins admitted work before native targeting using the existing incarnation ledger."
  def pin_scope(history, transcript_id, principal, owner, session) do
    Map.new(history, fn {server_id, entry} ->
      if entry.principal == principal and Map.has_key?(entry.cursors, transcript_id) and
           (is_nil(entry.retirement) or Map.has_key?(entry.pins, {owner, session})),
         do: {server_id, pin_entry(entry, owner, session)},
         else: {server_id, entry}
    end)
  end

  @doc "Pins a runtime in the same manager transition as its creation/reuse."
  def pin_runtime(history, server_id, owner, session) when is_reference(session) do
    case Map.fetch(history, server_id) do
      {:ok, entry} -> Map.put(history, server_id, pin_entry(entry, owner, session))
      :error -> history
    end
  end

  def pin_runtime(history, _server_id, _owner, _session), do: history

  defp pin_entry(entry, owner, session) do
    pins = Map.put_new_lazy(entry.pins, {owner, session}, fn -> Process.monitor(owner) end)
    %{entry | pins: pins}
  end

  @doc "Releases this caller's admission pins after completion, receipt transfer or failure."
  def release_pins(history, owner, session) do
    Map.new(history, fn {server_id, entry} ->
      {monitor, pins} = Map.pop(entry.pins, {owner, session})
      if monitor, do: Process.demonitor(monitor, [:flush])
      {server_id, %{entry | pins: pins}}
    end)
  end

  @doc "Reports local accepted work independently of retained native terminal records."
  def accepted_work?(entry),
    do: not is_nil(entry.lease) or entry.waiters != [] or map_size(entry.pins) > 0

  defp advance_waiter(%{waiters: []} = entry), do: entry

  defp advance_waiter(%{waiters: [waiter | remaining]} = entry) do
    entry = %{entry | waiters: remaining}
    owner = elem(waiter.from, 0)

    if Process.alive?(owner) and not deadline_expired?(waiter.deadline) do
      Process.demonitor(waiter.monitor, [:flush])
      {entry, lease} = grant(entry, waiter.from, input_id: waiter.input_id)

      reply =
        if waiter.reservation?, do: %{server_id: waiter.server_id, lease: lease}, else: lease

      GenServer.reply(waiter.from, {:ok, reply})
      entry
    else
      discard_waiter(waiter, :history_handoff_timeout)
      advance_waiter(entry)
    end
  end

  @doc "Removes an expired reservation; grant-time deadline checks prevent late timer delivery from granting it."
  def expire_waiter(history, server_id, id) do
    case Map.get(history, server_id) do
      nil ->
        history

      entry ->
        {expired, remaining} = Enum.split_with(entry.waiters, &(&1.id == id))
        Enum.each(expired, &discard_waiter(&1, :history_handoff_timeout))
        Map.put(history, server_id, %{entry | waiters: remaining})
    end
  end

  @doc "Drops a dead waiter without invalidating the current lease owner's runtime."
  def drop_waiter(history, monitor) do
    Map.new(history, fn {server_id, entry} ->
      pins = Map.reject(entry.pins, fn {_key, ref} -> ref == monitor end)

      {server_id,
       %{entry | pins: pins, waiters: Enum.reject(entry.waiters, &(&1.monitor == monitor))}}
    end)
  end

  defp schedule_expiry(%{deadline: nil}), do: :ok

  defp schedule_expiry(waiter) do
    delay = max(waiter.deadline - System.monotonic_time(:millisecond), 0)
    Process.send_after(self(), {:expire_history_waiter, waiter.server_id, waiter.id}, delay)
  end

  defp deadline_expired?(nil), do: false
  defp deadline_expired?(deadline), do: deadline <= System.monotonic_time(:millisecond)

  defp discard_waiter(waiter, reason) do
    Process.demonitor(waiter.monitor, [:flush])
    GenServer.reply(waiter.from, {:error, reason})
  end

  defp valid_cursors?(cursors) when is_map(cursors) and map_size(cursors) > 0 do
    Enum.all?(cursors, fn {key, position} ->
      is_binary(key) and key != "" and is_integer(position) and position >= 0
    end)
  end

  defp valid_cursors?(_), do: false

  @doc "Validates bounded projection storage without advancing the incorporated ledger."
  def validate_projection(_history, nil), do: :ok

  def validate_projection(
        %{projection: %{transcript_id: id}, cursors: cursors},
        %{kind: :canonical, transcript_id: id, messages: messages, cursors: next}
      )
      when is_list(messages) and length(messages) <= 151 do
    validate_next(cursors, next)
  end

  def validate_projection(_history, _projection), do: {:error, :invalid_history_projection}

  defp validate_next(previous, next) do
    valid? =
      valid_cursors?(next) and map_size(previous) == map_size(next) and
        Enum.all?(previous, fn {id, cursor} -> is_integer(next[id]) and next[id] >= cursor end)

    if valid?, do: :ok, else: {:error, :invalid_history_cursor}
  end
end
