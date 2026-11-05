defmodule AshBulkDurable.Core.Progress do
  @moduledoc """
  What a page following a bulk action is told while it runs.

  A bulk action keeps no progress counter of its own: `rows_done` counts its
  `:succeeded` rows, so nothing a run writes inside a chunk's transaction
  touches the bulk action's row (see `AshBulkDurable.Core.Lease`). Instead,
  when a run starts and after each chunk commits, the worker broadcasts on
  the bulk action's topic, `"bulk_action:<id>"`, through `:pubsub_module`.
  Phase 1 also broadcasts as its rows resolve, since each resolved row
  commits on its own:

    * event `"progress"`, payload `%{bulk_action_id: id, committed: true}` —
      the run started or committed rows; read the bulk action again to
      recount.
    * event `"progress"`, payload `%{bulk_action_id: id, committed: false,
      rows_processed: n, total_rows: m, started_at: t}` — an all-or-nothing
      run has processed `n` rows inside its one transaction, none of them
      saved yet. A hint only: nothing committed says so, and a page opened
      later can't rebuild it. `started_at` names the claim it came from
      (every claim resets it), so a page can ignore a run that lost its
      claim but is still going.

  The committed broadcast is sent at most once per `:progress_interval`
  (a second by default) per bulk action from a run, since every page
  following the bulk action answers it by counting the rows again. The
  first is always sent, and so is the one at the end of phase 1: a page that
  missed it would go on showing references being resolved all through an
  all-or-nothing run's write, since that commits nothing until it ends. The
  bulk action's finish arrives as its own notification.

  `rows_done` and `rows_pending` are aggregates, loaded only when asked for
  (`load: [:rows_done, :rows_pending]`): a page showing progress loads them,
  and the queue's own reads don't count rows.

  The second also runs as the telemetry event `[:ash_bulk_durable,
  :all_or_nothing, :progress]` with measurements `%{rows_processed: n}`.

  The bulk action's own updates (finished, retried) still arrive as the
  resource's `Ash.Notifier.PubSub` notifications on the same topic.
  """

  @progress_interval 1_000

  @doc """
  Tells a page that `bulk_action` started or committed rows: read it again.
  Throttled by `:progress_interval`, unless `force: true`, for a change a page
  must not miss.
  """
  def changed(bulk_action, opts \\ []) do
    if due?(bulk_action.id, Keyword.get(opts, :force, false)),
      do: broadcast(bulk_action, %{bulk_action_id: bulk_action.id, committed: true}),
      else: :ok
  end

  # Per run, so kept in the run's own process.
  defp due?(id, force?) do
    interval = AshBulkDurable.Core.config(:progress_interval, @progress_interval)
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, id}

    case Process.get(key) do
      last when not force? and is_integer(last) and now - last < interval ->
        false

      _never_due_or_forced ->
        Process.put(key, now)
        true
    end
  end

  @doc "Tells a page that an all-or-nothing run processed `n` rows, not saved yet."
  def uncommitted(bulk_action, n) do
    :telemetry.execute(
      [:ash_bulk_durable, :all_or_nothing, :progress],
      %{rows_processed: n},
      %{bulk_action_id: bulk_action.id, total_rows: bulk_action.total_rows}
    )

    broadcast(bulk_action, %{
      bulk_action_id: bulk_action.id,
      committed: false,
      rows_processed: n,
      total_rows: bulk_action.total_rows,
      started_at: bulk_action.started_at
    })
  end

  # Best effort: a page that misses one catches up on the next.
  defp broadcast(bulk_action, payload) do
    case AshBulkDurable.Core.config(:pubsub_module) do
      nil -> :ok
      pubsub -> pubsub.broadcast("bulk_action:#{bulk_action.id}", "progress", payload)
    end

    :ok
  rescue
    _exception -> :ok
  end
end
