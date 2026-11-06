defmodule AshBulkDurable.Core.Liveness do
  @moduledoc """
  The liveness hint: a bulk action's `alive_at`, stamped on the database's
  clock while a run goes, so a poller can tell a run that is still going from
  one whose node died.

  It decides only when to start a run, never whether a write is allowed: the
  bulk action lock (`AshBulkDurable.Core.BulkActionLock`) does that. A second
  run started on a live bulk action is harmless, so a hint that goes stale
  while its run is alive only wastes work.

  A run stamps it in its start transaction and in every phase-2 chunk it
  commits. Between those, phase 1 can spend minutes on one row, and an
  all-or-nothing chunk holds the lock for as long as it runs, so a ticker
  linked to the run (`start_ticker/1`) also stamps it every
  `:alive_interval` (milliseconds, 30 seconds by default, in the
  `ash_bulk_durable` config). The ticker takes the lock with `SKIP LOCKED`
  and skips the stamp when another transaction holds it, never waiting: a
  chunk holding it is alive, and stamps when it commits.

  The run's own locked transactions take the same lock with `SKIP LOCKED`,
  and one that found the ticker's stamp holding it would stop the run as if
  another worker held the bulk action. So the run holds its ticker around
  each of them (`hold/1`, `release/1`): `hold/1` waits for a stamp in
  flight, and the ticker skips its ticks until `release/1`. Those
  transactions stamp, or need no stamp, so nothing is lost.
  """

  import Ash.Expr, only: [expr: 1]

  require Ash.Expr
  require Logger

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.BulkActionLock

  @alive_interval :timer.seconds(30)

  @doc """
  Stamps `bulk_action`'s `alive_at` with the database's clock. Call it with
  the bulk action locked, in the transaction that holds the lock. Nothing is
  announced: the stamp changes nothing a page shows.
  """
  def stamp!(bulk_action) do
    {:ok, _stamped, _notifications} =
      Ash.update(bulk_action, %{},
        action: :stamp_alive,
        authorize?: false,
        return_notifications?: true
      )

    :ok
  end

  @doc """
  A filter on the bulk action resource matching what a poller may start: one
  `:queued`, or one whose `alive_at` is missing or older than `stale_after`
  milliseconds on the database's clock.
  """
  def startable(stale_after) do
    expr(
      status == :queued or is_nil(alive_at) or
        alive_at <
          fragment(
            "((now() AT TIME ZONE 'utc') - (? * interval '1 millisecond'))",
            ^stale_after
          )
    )
  end

  @doc """
  Starts a process linked to the caller that stamps the bulk action
  `bulk_action_id` every `:alive_interval` until `stop_ticker/1`. It runs
  with the caller's `$callers`, so a test's sandboxed connection reaches it.
  """
  def start_ticker(bulk_action_id) do
    interval = Core.config(:alive_interval, @alive_interval)

    {:ok, pid} =
      Task.start_link(fn -> tick(bulk_action_id, interval, next_tick(interval), false) end)

    pid
  end

  @doc """
  Keeps `ticker` from stamping until `release/1`: returns once any stamp it
  is making has committed. `nil`, no ticker, holds nothing.
  """
  def hold(nil), do: :ok

  def hold(ticker) do
    ref = Process.monitor(ticker)
    send(ticker, {:hold, self(), ref})

    receive do
      {^ref, :held} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^ticker, _reason} ->
        :ok
    end
  end

  @doc "Lets `ticker` stamp again after `hold/1`."
  def release(nil), do: :ok

  def release(ticker) do
    send(ticker, :release)
    :ok
  end

  @doc """
  Stops a ticker `start_ticker/1` started. A stamp it is making finishes
  first: it never waits for the lock, so that is short.
  """
  def stop_ticker(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 ->
        Process.exit(pid, :kill)
        :ok
    end
  end

  # Ticks keep to their schedule however often the run holds and releases
  # the ticker; a tick that falls while it is held is skipped.
  defp tick(bulk_action_id, interval, next_at, held?) do
    wait = max(next_at - System.monotonic_time(:millisecond), 0)

    receive do
      :stop ->
        :ok

      {:hold, from, ref} ->
        send(from, {ref, :held})
        tick(bulk_action_id, interval, next_at, true)

      :release ->
        tick(bulk_action_id, interval, next_at, false)
    after
      wait ->
        unless held?, do: stamp_unless_busy(bulk_action_id)
        tick(bulk_action_id, interval, next_tick(interval), held?)
    end
  end

  defp next_tick(interval), do: System.monotonic_time(:millisecond) + interval

  # A stamp that fails is only a missed hint: the run goes on.
  defp stamp_unless_busy(bulk_action_id) do
    Ash.transaction([Core.config(:bulk_action_resource)], fn ->
      case BulkActionLock.lock(bulk_action_id, [:queued, :running]) do
        {:ok, locked} -> stamp!(locked)
        :none -> :skipped
      end
    end)
  rescue
    exception ->
      Logger.warning(
        "ash_bulk_durable: bulk action #{bulk_action_id} missed a liveness stamp: " <>
          Exception.message(exception)
      )
  end
end
