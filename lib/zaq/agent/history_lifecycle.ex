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
  def initialize(history, server_id, pid, cursors, principal \\ nil, generations \\ nil) do
    history = drop(history, server_id)

    if is_nil(cursors),
      do: history,
      else:
        Map.put(history, server_id, %{
          pid: pid,
          principal: principal,
          cursors: cursors,
          generations: generations || Map.new(cursors, fn {id, _} -> {id, 0} end),
          lease: nil,
          waiters: []
        })
  end

  @doc "Validates initial Engine generation bindings against the exact source vector."
  def validate_generations(_cursors, nil), do: :ok

  def validate_generations(cursors, generations) do
    if valid_cursors?(cursors) and valid_cursors?(generations) and
         Enum.sort(Map.keys(cursors)) == Enum.sort(Map.keys(generations)),
       do: :ok,
       else: {:error, :invalid_history_generation}
  end

  @doc "Grants a process-owned lease, or defers another caller without advancing its cursor."
  def begin_request(history, server_id, pid, from) do
    case Map.get(history, server_id) do
      %{pid: ^pid, lease: nil} = entry ->
        {entry, lease} = grant(entry, from)
        {:reply, {:ok, lease}, Map.put(history, server_id, entry)}

      %{pid: ^pid, lease: %{owner: owner}} when elem(from, 0) == owner ->
        {:reply, {:error, :history_request_active}, history}

      %{pid: ^pid} = entry ->
        {:wait, Map.put(history, server_id, %{entry | waiters: entry.waiters ++ [from]})}

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
        Enum.each(entry.waiters, &GenServer.reply(&1, {:error, reason}))
    end

    Map.delete(history, server_id)
  end

  defp grant(entry, {owner, _tag}) do
    lease = %{
      token: make_ref(),
      owner: owner,
      monitor: Process.monitor(owner),
      op_id: Jido.Util.generate_id(),
      pid: entry.pid,
      cursors: entry.cursors
    }

    {%{entry | lease: lease}, Map.take(lease, [:token, :op_id, :pid, :cursors])}
  end

  defp advance_waiter(%{waiters: []} = entry), do: entry

  defp advance_waiter(%{waiters: [{owner, _tag} = from | remaining]} = entry) do
    entry = %{entry | waiters: remaining}

    if Process.alive?(owner) do
      {entry, lease} = grant(entry, from)
      GenServer.reply(from, {:ok, lease})
      entry
    else
      advance_waiter(entry)
    end
  end

  defp valid_cursors?(cursors) when is_map(cursors) and map_size(cursors) > 0 do
    Enum.all?(cursors, fn {key, position} ->
      is_binary(key) and key != "" and is_integer(position) and position >= 0
    end)
  end

  defp valid_cursors?(_), do: false

  defp validate_next(previous, next) do
    valid? =
      valid_cursors?(next) and map_size(previous) == map_size(next) and
        Enum.all?(previous, fn {id, cursor} -> is_integer(next[id]) and next[id] >= cursor end)

    if valid?, do: :ok, else: {:error, :invalid_history_cursor}
  end
end
