defmodule AshBulkDurable.Core.Progress do
  @moduledoc """
  Progress a page can see while a run commits nothing to the bulk action.

  A page following a bulk action otherwise learns of progress only from the
  bulk action's own committed updates: `rows_done`, bumped in each chunk's
  transaction and announced by `Ash.Notifier.PubSub` after the commit. That
  leaves two stretches where it sees nothing:

    * an all-or-nothing run writes every row in one transaction, so nothing
      is announced until it ends;
    * in either mode, phase 1 commits each row it resolves, but never updates
      the bulk action.

  For those, the worker broadcasts event `"progress"` on the bulk action's
  topic, `"bulk_action:<id>"`, through the `:pubsub_module` config (as
  `pubsub_module.broadcast(topic, "progress", payload)`), and nothing when it
  is unset. The payloads:

    * **Writing, all or nothing.** Sent as each slice of the one transaction
      runs (Ash's stream batch size, 100 rows by default). A hint only:
      nothing is saved until the transaction commits, and a rollback throws
      it all away.

          %{
            bulk_action_id: id,
            pass: pass,
            phase: :writing,
            committed: false,
            rows_processed: n,
            total_rows: m
          }

    * **Resolving, phase 1, both modes.** Sent as rows resolve or fail.
      `rows_resolved` counts the rows this run has taken out of `:pending`,
      resolved or failed, so it reaches `rows_to_resolve` when phase 1 is
      done; `rows_to_resolve` is the rows that were `:pending` when it began.
      Each of those rows is committed.

          %{
            bulk_action_id: id,
            pass: pass,
            phase: :resolving,
            committed: true,
            rows_resolved: n,
            rows_to_resolve: m
          }

  `pass` is the bulk action's `pass` the run started in. A page should ignore
  a payload whose `pass` differs from the bulk action it holds: it comes from
  a run a retry has since replaced. And it should drop the hint once the bulk
  action's `status`, `pass` or `rows_done` changes. Not on every update of
  it: a run's liveness stamps update the bulk action too, and say nothing
  about its rows. The bulk action's own updates arrive on the same topic as
  before, as the resource's `Ash.Notifier.PubSub` notifications.

  Each kind is sent at most once per `:progress_interval` milliseconds (1000
  by default; `0` sends every one) per run. The first is always sent, and so
  is the last of phase 1, so a page never stays on "resolving" through a long
  all-or-nothing write.

  The same throttled reports run as the telemetry events
  `[:ash_bulk_durable, :all_or_nothing, :progress]`, with measurements
  `%{rows_processed: n, total_rows: m}`, and
  `[:ash_bulk_durable, :phase1, :progress]`, with measurements
  `%{rows_resolved: n, rows_to_resolve: m}`. Both carry `%{bulk_action_id:
  id, pass: pass}` as metadata. They are sent whether or not
  `:pubsub_module` is set.

  ## Best effort

  A page that misses one catches up on the next, or on the bulk action's own
  next update, so nothing here may fail or slow a run: every report rescues
  whatever it raises, throws or exits with. A broadcast is sent from inside
  the all-or-nothing run's locked transaction. That is allowed because it is
  neither storage nor network I/O (rule R9): a web endpoint's broadcast,
  with the default local or distributed-Erlang pubsub adapter, is a
  non-blocking send to the local subscribers and the adapter, with nothing
  that waits for a reply. Other adapters may not be: one backed by Redis,
  say, can publish over the network before it returns, and would then hold
  the lock while it does. A `:pubsub_module` must keep the broadcast
  non-blocking: no `GenServer.call`, no network round trip, nothing that
  waits. On such an adapter, wrap `broadcast/3` in a module that hands the
  hint to a local process first.

  The throttle and phase 1's count live in the run's own process, and
  `forget/1` clears them when the run ends.
  """

  require Logger

  @progress_interval 1_000

  @doc """
  Starts phase 1's count for `bulk_action`: `rows_to_resolve` rows are
  `:pending`. Sends nothing.
  """
  def resolving_started(bulk_action, rows_to_resolve) do
    Process.put(resolving_key(bulk_action.id), %{
      pass: bulk_action.pass,
      rows_resolved: 0,
      rows_to_resolve: rows_to_resolve
    })

    :ok
  end

  @doc """
  Counts one row of `bulk_action_id` resolved or failed in phase 1, and
  reports the count when the throttle allows.
  """
  def row_resolved(bulk_action_id) do
    case Process.get(resolving_key(bulk_action_id)) do
      nil ->
        :ok

      state ->
        state = %{state | rows_resolved: state.rows_resolved + 1}
        Process.put(resolving_key(bulk_action_id), state)
        report_resolving(bulk_action_id, state, false)
    end
  end

  @doc """
  Ends phase 1's count for `bulk_action_id`, and always reports its last
  count.
  """
  def resolving_finished(bulk_action_id) do
    case Process.delete(resolving_key(bulk_action_id)) do
      nil -> :ok
      state -> report_resolving(bulk_action_id, state, true)
    end
  end

  @doc """
  Reports that an all-or-nothing `bulk_action` has processed `rows_processed`
  rows inside its open transaction, when the throttle allows.
  """
  def writing(bulk_action, rows_processed) do
    total_rows = bulk_action.total_rows
    n = min(rows_processed, total_rows)

    report(
      :writing,
      bulk_action.id,
      bulk_action.pass,
      false,
      [:ash_bulk_durable, :all_or_nothing, :progress],
      %{rows_processed: n, total_rows: total_rows},
      %{committed: false}
    )
  end

  @doc """
  Clears what this process keeps for `bulk_action_id`'s run: phase 1's count
  and the throttle's last sends. The worker calls it when a run ends, so a
  long-lived process that runs many keeps nothing, and its next run of the
  same bulk action sends its first hint at once.
  """
  def forget(bulk_action_id) do
    for {{__MODULE__, _kind, _phase, ^bulk_action_id, _pass} = key, _value} <- Process.get(),
        do: Process.delete(key)

    Process.delete(resolving_key(bulk_action_id))
    :ok
  end

  defp report_resolving(bulk_action_id, state, force?) do
    n = min(state.rows_resolved, state.rows_to_resolve)

    report(
      :resolving,
      bulk_action_id,
      state.pass,
      force?,
      [:ash_bulk_durable, :phase1, :progress],
      %{rows_resolved: n, rows_to_resolve: state.rows_to_resolve},
      %{committed: true}
    )
  end

  defp report(phase, bulk_action_id, pass, force?, event, counts, extra) do
    if due?(phase, bulk_action_id, pass, force?) do
      metadata = %{bulk_action_id: bulk_action_id, pass: pass}
      :telemetry.execute(event, counts, metadata)

      metadata
      |> Map.put(:phase, phase)
      |> Map.merge(extra)
      |> Map.merge(counts)
      |> broadcast()
    end

    :ok
  catch
    kind, reason ->
      Logger.debug(fn -> "progress report failed: #{Exception.format(kind, reason)}" end)
      :ok
  end

  # Per run and per kind, so kept in the run's own process.
  defp due?(phase, bulk_action_id, pass, force?) do
    interval = AshBulkDurable.Core.config(:progress_interval, @progress_interval)
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, :sent, phase, bulk_action_id, pass}

    case Process.get(key) do
      last when not force? and is_integer(last) and now - last < interval ->
        false

      _never_due_or_forced ->
        Process.put(key, now)
        true
    end
  end

  defp broadcast(%{bulk_action_id: id} = payload) do
    case AshBulkDurable.Core.config(:pubsub_module) do
      nil -> :ok
      pubsub -> pubsub.broadcast("bulk_action:#{id}", "progress", payload)
    end
  end

  defp resolving_key(bulk_action_id), do: {__MODULE__, :resolving, bulk_action_id}
end
