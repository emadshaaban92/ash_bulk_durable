defmodule AshBulkDurable.Core.Worker do
  @moduledoc """
  Drives a single `BulkAction` through phase 1 (resolving its rows'
  references) and phase 2 (the chunk loop).

  ## Running

  `run/2` is the run: a plain function, given the bulk action's id, that
  drives it from where its rows stand to its verdict. A host's
  `AshBulkDurable.Core.Poller` calls it in a task for each bulk action it
  starts.

  `run_now/1` and `drain/0` run bulk actions in the calling process, for a
  host's tests and scripts: `run_now/1` runs one, and `drain/0` every bulk
  action that is `:queued` or `:running`, oldest first. Phase 1's tasks
  inherit the caller's `$callers`, so a test's sandboxed connection reaches
  them.

  ## Crash-resume

  A run can die anywhere and start again, because the row-state mutation IS
  the pagination. Phase 1 reads `:next_pending_chunk` (rows still
  `:pending`; a row holding no reference is stored `:resolved` and never
  read here) and flips them to `:resolved`; phase 2 reads
  `:next_resolved_chunk` (rows `:resolved` but not yet applied) and flips
  them to `:succeeded`. The next run resumes at the next un-touched row in
  whichever phase the last died in — no row committed twice.

  A node that dies leaves its bulk action `:running`. Its liveness hint
  (`alive_at`, see `AshBulkDurable.Core.Liveness`) stops moving, and once it
  is older than the poller's `:stale_after` a poller starts the bulk action
  again, which resumes the same way. A run stamps the hint in its start
  transaction and in every chunk it commits, and a ticker linked to the run
  stamps it every `:alive_interval` between them.

  ## The bulk action lock

  Every phase-2 chunk runs in a transaction of its own that first locks the
  bulk action's row (`AshBulkDurable.Core.BulkActionLock`, `FOR NO KEY UPDATE
  SKIP LOCKED`) while it is `:queued` or `:running`, and only then reads its
  next rows, writes their targets, flips them and bumps `rows_done`. The one
  that finds no row left, or writes the last, writes the verdict. Before
  phase 1, a short locked transaction of its own starts the run: it takes
  the bulk action from `:queued` to `:running` and sets `started_at`, and a
  run that can't take the lock there stops before phase 1. Every
  verdict, phase 1's included, is written under the lock, from the record
  read under it. A chunk that fails rolls back with the lock; per row, its
  rows are then recovered (see "Recovering a failed chunk" below), each try
  in a locked transaction of its own, and a row that still fails alone is
  marked in a further one.

  Postgres releases the lock at commit, at rollback and when a connection
  dies, so a run that lost it has nothing left that can commit. A lock
  another transaction holds stops the run at once, writing nothing; `run/2`
  returns `:busy` when that happens at the run's start, and `:ok` after it.

  The lock covers only what is written on the bulk action's own connection,
  so every target must live in the bulk action's repo.

  Phase 1 runs outside the lock: it reaches for files and lookups, which can
  take minutes a row. Its single-row writes (a row's `:resolve`, and the
  `:mark_failed` of a row that failed to resolve or lost its staged files)
  are compare-and-sets instead: each matches its row only while the row is
  in the status it may leave, and on the run's pass (see "Overlapping runs"
  and "Passes" below).

  ## Failure surface

  - A bulk action storing what no longer decodes (`StoredTerm`) →
    `:mark_finished({:failed, %{reason: :unreadable}})`, nothing run. A row
    storing it fails alone.
  - A bulk action whose resource or action no longer exists (renamed or
    removed by a deploy) → `:mark_finished({:failed, %{reason: :gone}})`,
    nothing run.
  - Staged-file download error, with a row left for a resolver → each such
    row fails alone (`StagedFileError`) and the rest run. All or nothing →
    `:mark_finished({:failed, %{reason: :staged_file_download_error, ...}})`.
    Does NOT raise; we want a real terminal state, not a run that fails the
    same way every time it is started.
  - A resolver's `prepare/2` error for a chunk →
    `:mark_finished({:failed, %{reason: :resolver_prepare_error, ...}})`.
  - All-or-nothing phase 1 failure, or a row its caller already refused →
    `:mark_finished({:failed, %{reason: :atomic_phase1_failed, ...}})`.
  - All-or-nothing chunk rollback → `:mark_finished({:failed, %{reason:
    :atomic_chunk_rolled_back, ...}})`.
  - Per-row chunk rollback → recovery, halving the chunk's rows (rows
    succeed or fail individually); the bulk action lands in
    `:completed_with_errors` if any row landed `:failed`.
  - A row status flip refused because another run of the bulk action already
    moved the row on (`RowMovedOnError`, see below) → the run stops, writing
    no verdict.
  - An exception raised after the run's start and before its first row
    (rebuilding the owner's scope, the runner's settings, asking storage
    which resolutions were lost, downloading the staged files) → counted
    under the lock as a setup failure, then raised again. The
    `:max_setup_failures`th with no progress between →
    `:mark_finished({:failed, %{reason:
    :setup_error, message: ...}})`, the exception's message, before it is
    raised. See "Setup failures" in "Crashes" below.

  A row that raises, or outruns `:row_resolve_timeout` in phase 1, fails like
  one that returns an error, in either phase and either mode. Only a raise from the worker's own reads and writes propagates
  out of the run; the bulk action stays `:running`, and is started again once
  its liveness hint goes stale.

  ## Recovering a failed chunk

  A per-row chunk whose rows return errors (a validation error, a constraint
  violation; a row that raises counts too) rolls back as a whole, so its
  rows are tried again in smaller sets, each set in a locked transaction of
  its own (`SKIP LOCKED`). Each try reads again, under the lock and on its
  connection, which of its rows are still `:resolved`, and drops the rest:
  another run applied them, or a retry reopened them. A lock it can't take
  stops the whole recovery, since the run holding it reads these same rows
  and recovers them itself.

  - **Halving.** The failed rows split in two, and each half is tried in
    turn. A half that succeeds commits; one that fails splits again. A
    single row that fails is marked failed, with its own error, in a further
    locked transaction and only while it is still `:resolved`. With k bad
    rows among n, that is about 2·k·log2(n/k) transactions instead of n.
  - **Row by row.** A set at or below `:halving_min_rows` runs one row at a
    time, as does the second half of a split whose first half failed too,
    once halving that first half cost at least what row by row would have (a
    run alone for each row and a mark for each that failed): many bad rows
    then cost little more than row by row, a few spread across both halves
    are still halved.

  The first half is recovered before the second is tried, so rows commit in
  the order the chunk read them, and each failing row is marked with the
  error it gave running alone: the rows that succeed, those that fail and
  their errors are the ones running every row alone gives. Crashes are
  another matter, and rows suspected of them run alone (see "Crashes"
  below).

  In the `ash_bulk_durable` config:

    * `:halving_min_rows` - sets of at most this many rows run row by row,
      8 by default. 0 turns halving off: every row of a failed chunk runs
      alone.

  ## Crashes

  A run can also die without returning: its process killed, the node out of
  memory, a NIF crashing it. Nothing after that runs, so what tells such a
  run apart is committed before the work it might die in.

  - **Stalled starts.** Each run's start transaction, under the lock, scores
    the bulk action's progress: its rows no longer `:pending`, plus those
    `:succeeded` or `:failed`, so phase 1's progress counts too. A score
    higher than the last start stored (`progress_at_start`), or no last
    start, sets `stalled_starts` back to 0; the same score adds 1. A start
    that can't take the lock counts nothing.
  - **Isolation.** A start that brings `stalled_starts` to
    `:max_stalled_starts` runs the pass in isolation. Per row, every row
    left runs alone, in phase 1 and in phase 2, its `attempts` bumped in a
    locked transaction that commits before the row runs, and that names it
    as `isolating_row_id`. All or nothing has no row to run alone: the start
    transaction fails it, `{:failed, %{reason: :crashed}}`, its rows as they
    were. A pass that makes progress takes the next start back to chunks.
  - **Suspect rows.** A row still `:pending` or `:resolved` with `attempts`
    above 0 was running alone when a run died. In every pass each such row
    runs alone first, its `attempts` bumped the same way, and the chunks
    leave it out. Resolving a row gives back the bump its run alone took, so
    one run through both phases counts once; bumps earlier runs died with
    stay. A row that ran alone and succeeded keeps its `attempts`.
  - **Giving up on a row.** A row met with `:max_row_attempts` attempts is
    not run again: it fails with `AshBulkDurable.Core.CrashedRowError`,
    under the lock and only while it is still in the status it was read in,
    and the rest runs on. The bulk action ends `:completed_with_errors`.
  - **A shutdown is not a crash.** A run the poller kills once its
    `:shutdown_grace` is over gets `shutdown_stopped` set (see
    `AshBulkDurable.Core.Poller`). The next start clears it without counting
    a stalled start, and gives back the bump of the row it names as
    `isolating_row_id`, if that row is still to run. A row's run alone
    clears `isolating_row_id` in the transaction that records how it went
    (phase 1's resolve, phase 2's run alone or its failure), so a bump given
    back once is never given back again. Every give-back is an atomic
    `attempts - 1` that stops at 0.
  - **Setup failures.** A run that raises before its first row moves none,
    so a per-row one would be restarted forever, its stalled starts only
    isolating rows it never reaches. Each such exception is counted in
    `setup_failures`, under the lock, and the one that brings it to
    `:max_setup_failures` fails the bulk action, `{:failed, %{reason:
    :setup_error}}`. Only exceptions count: a run killed in its setup (the
    stress test's chaos, a shutdown, a node lost) adds nothing, and nor
    does an exit, such as a `GenServer.call` timeout in a storage client.
    Only a start whose score rose sets it back to 0: one whose setup
    succeeds but that makes no progress leaves it as it is.
  - **A retry starts the count again**: `:enqueue_retry` clears the five
    fields, and `:reopen_with_corrections` a reopened row's `attempts`.
    Returned errors are not crashes, and bump nothing.

  The start that enters isolation logs a warning and emits
  `[:ash_bulk_durable, :isolation, :start]` (measurements `stalled_starts`;
  metadata `bulk_action_id`, `mode`); failing a row as crashed logs an error
  and emits `[:ash_bulk_durable, :row, :crashed]` (measurements `attempts`;
  metadata `bulk_action_id`, `row_id`, `row_index`).

  In the `ash_bulk_durable` config:

    * `:max_stalled_starts` - starts in a row without progress before a pass
      runs in isolation, 3 by default.
    * `:max_row_attempts` - runs alone that may die on a row before it fails
      as crashed, 2 by default.
    * `:max_setup_failures` - starts that raise before reaching a row, with
      no progress between, before the bulk action fails, 3 by default.

  ## Telemetry

  A chunk emits `[:ash_bulk_durable, :chunk, :start | :stop | :exception]`.
  `:stop` comes once the chunk committed, or after its recovery, with
  measurements `duration`, `rows_in_chunk`, `rows_succeeded`, `rows_failed`
  and `transactions`, the locked transactions the chunk took, its own
  included (1 for a chunk that committed; 2 for an all-or-nothing one rolled
  back, with its verdict's), and metadata `bulk_action_id`, `chunk_index`,
  `outcome` (`:ok` or `:rolled_back`) and `recovery`: `:none`, `:halving`,
  or `:row_by_row` when halving is off, the chunk was at or below
  `:halving_min_rows`, or a half fell back to row by row.

  ## Progress a page can see

  Phase 1 commits rows but never the bulk action, and an all-or-nothing
  write commits nothing until it ends, so neither shows on the bulk action's
  own updates. Both send throttled `"progress"` broadcasts and telemetry
  instead, as rows resolve and as the one transaction's slices run: see
  `AshBulkDurable.Core.Progress`.

  ## Tenants

  A row acts in its target's tenant, or the bulk action's. Phase 1 resolves
  a chunk's tenant references first, then the rows' input references tenant
  by tenant, each tenant's resolvers prepared once. Phase 2 writes each row
  in its tenant; an all-or-nothing bulk action spanning tenants is still one
  transaction.

  ## Staged-file tmp cleanup

  Staged files land in a Briefly-managed tmp file. The eager
  `delete_local_staged_tmp/1` after `run_rows/3` returns
  removes them on the happy path; if the worker process crashes
  between download and that call, Briefly's `:DOWN` handler still
  cleans them up. Only a hard VM kill (`kill -9`, OOM-killer) can
  leak — at which point the OS tmp sweeper is the fallback.

  ## Idempotency on terminal bulk actions

  `run/2` short-circuits to `:ok` when the bulk action is already in a
  terminal state. A bulk action that turns terminal after that read is found
  so under the lock, and left as it is.

  ## Overlapping runs

  Two runs can overlap: two pollers can start the same bulk action, and a run
  can be started again while its first is still alive but has not stamped
  its hint in time. Between chunks a run holds nothing, so two runs take
  turns: each chunk reads the rows the last one left, and only one verdict is
  written, since a bulk action the other run finished no longer locks as
  running. Both may resolve the same rows in phase 1, which costs work, not
  data.

  Each row status flip is also a compare-and-set
  (`AshBulkDurable.Core.Changes.RequireStatus`), which is phase 1's only
  guard, and catches any phase-2 write that slips past the lock: the run that
  comes second to a row is refused, and the transaction holding the refused
  flip rolls back with whatever it wrote. The run then stops without writing
  anything more, and no verdict, returning `{:stopped, :row_moved_on}`; the
  other run carries the bulk action on.

  The verdict is written only once no row is `:pending` or `:resolved`. A
  row another run put back to `:pending`, its resolutions lost, leaves a
  run that finds no `:resolved` row to stop without one: that run, or the
  next start, finishes it.

  ## Passes

  A retry reopens a finished bulk action with what may be a corrected shared
  input, and bumps its `pass`. A run keeps the pass its start transaction
  locked, and every lock it takes after that (chunks, recovery, rows run
  alone, verdicts, forgotten resolutions, its ticker's stamps) matches only
  that pass. A run that stalled past a verdict and a retry finds its next
  lock refused, as if another run held it, and stops: it never applies the
  new pass's rows with the old pass's settings, or writes the old pass's
  verdict.

  Phase 1's single-row writes take no lock, so they check the pass
  themselves: each gives the run's pass in its action context, and
  `AshBulkDurable.Core.Changes.RequireStatus` then matches the row only
  while the row's own `pass` is that one. A retry writes its pass onto every
  row it reopens, in the transaction that bumps the bulk action's. A run
  still in phase 1 when a retry reopens its row to `:pending` has its write
  of that row refused, as one another run moved on, and stops, even when the
  write waited on the row while the retry held it: it never resolves the new
  pass's row with the old pass's shared input.

  Every read made under the lock runs on the lock's connection
  (`AshBulkDurable.Core.BulkActionLock.pin/1`), never on a `:read` repo.
  """

  alias AshBulkDurable.Core.{
    BulkActionLock,
    CrashedRowError,
    Introspection,
    Liveness,
    Progress,
    Reference,
    Runner,
    StagedFileError,
    Storage,
    StoredTerm
  }

  alias AshBulkDurable.Core.Worker.RowMovedOnError

  require Ash.Expr
  require Ash.Query
  require Logger

  @runnable [:queued, :running]
  @ticker {__MODULE__, :ticker}

  # A row's files run one after another, each an extraction and a PUT.
  @row_resolve_timeout :timer.minutes(5)

  @doc """
  Runs the bulk action `bulk_action_id` once, in the calling process: phase 1,
  then phase 2, up to its verdict.

  Returns `:busy` when the run's start couldn't take the bulk action's lock,
  another transaction holding it, the bulk action no longer queued or
  running, or, with `:if_stale_after`, its liveness hint still fresh, and
  nothing was written; `{:stopped, :row_moved_on}` when another run had
  moved one of its rows on, which stopped this one without a verdict; and
  `:ok` otherwise: the run reached a verdict, found nothing left to do (the
  bulk action is terminal), or stopped once started because another
  transaction took the lock, leaving the bulk action to that one. `:ok` is
  not a verdict: read the bulk action's status for that. Raises what the
  run's own reads and writes raise.

  `opts`:

    * `:if_stale_after` - milliseconds. A `:running` bulk action whose
      liveness hint (`alive_at`) is newer than that, on the database's clock,
      is left alone, returning `:busy`: another run just started or stamped
      it. Checked under the lock, in the run's start transaction. Nil by
      default, which starts the bulk action whatever its hint; the poller
      passes its `:stale_after`.
  """
  @spec run(Ash.UUID.t(), keyword()) :: :ok | :busy | {:stopped, :row_moved_on}
  def run(bulk_action_id, opts \\ []) do
    bulk_action = fetch_bulk_action!(bulk_action_id)

    if terminal?(bulk_action.status) do
      :ok
    else
      try do
        attempt(bulk_action, opts)
      rescue
        RowMovedOnError -> {:stopped, :row_moved_on}
      end
    end
  end

  @doc """
  Runs the bulk action `bulk_action_id` now, in the calling process, and
  returns what `run/2` returns. Phase 1's tasks inherit the caller's
  `$callers`, so a test's sandboxed connection reaches them.

  For hosts' tests and scripts: a test runs the bulk action it just submitted
  without a queue.
  """
  @spec run_now(Ash.UUID.t()) :: :ok | :busy | {:stopped, :row_moved_on}
  def run_now(bulk_action_id), do: run(bulk_action_id)

  @doc """
  Runs, oldest first and in the calling process, every bulk action that is
  `:queued` or `:running`, including any queued while it drains. Each runs at
  most once per call, so one left `:running` (busy, or stopped by a row
  another run moved on) can't loop forever. Returns how many it ran.

  For hosts' tests and scripts, as `run_now/1`.
  """
  @spec drain() :: non_neg_integer()
  def drain, do: drain(MapSet.new())

  defp drain(ran) do
    case next_runnable(ran) do
      nil ->
        MapSet.size(ran)

      bulk_action ->
        run_now(bulk_action.id)
        drain(MapSet.put(ran, bulk_action.id))
    end
  end

  defp next_runnable(ran) do
    ran = MapSet.to_list(ran)

    bulk_action_resource()
    |> Ash.Query.filter(status in [:queued, :running] and id not in ^ran)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp attempt(bulk_action, opts) do
    case unrunnable(bulk_action) do
      nil ->
        emit_worker_attempt_start(bulk_action)

        bulk_action
        |> start_run(Keyword.get(opts, :if_stale_after))
        |> run_started()

      reason ->
        finish_locked(bulk_action, {:failed, %{reason: reason}})
        :ok
    end
  end

  # Why the bulk action can never run, checked before its start is counted:
  # a run of it would raise before reaching a row on every start, and a
  # per-row one would be restarted forever. Nil when it can run.
  defp unrunnable(bulk_action) do
    cond do
      StoredTerm.unreadable?(bulk_action) -> :unreadable
      Introspection.runnable(bulk_action) == {:error, :gone} -> :gone
      true -> nil
    end
  end

  # The ticker stamps the liveness hint for as long as the run goes, and stops
  # with it however it ends.
  defp run_started({:ok, running}) do
    if entered_isolation?(running), do: announce_isolation(running)

    if terminal?(running.status), do: :ok, else: drive_started(running)
  end

  defp run_started(:busy), do: :busy

  defp drive_started(running) do
    ticker = Liveness.start_ticker(running.id, running.pass)
    Process.put(@ticker, ticker)

    try do
      drive_with_telemetry(running)
    after
      Process.delete(@ticker)
      Liveness.stop_ticker(ticker)
    end
  end

  # A run starts in a short locked transaction of its own, before phase 1:
  # it takes the bulk action from `:queued` to `:running`, sets `started_at`
  # and stamps the liveness hint, so the run shows as running, and is timed,
  # while its references resolve. A run that can't take the lock stops here,
  # before repeating another run's phase 1, as does one asked to leave a
  # bulk action another run stamped within `if_stale_after`. It counts the
  # start too (see "Crashes" above), and fails an all-or-nothing bulk action
  # that has stalled out.
  defp start_run(bulk_action, nil), do: locked(bulk_action.id, &started/1, @runnable, true)

  defp start_run(bulk_action, if_stale_after),
    do: locked(bulk_action.id, &started/1, @runnable, Liveness.startable(if_stale_after))

  defp started(locked) do
    Liveness.stamp!(locked)
    give_back_if_shut_down(locked)
    score = progress_score(locked)

    counted =
      count_crashes!(locked, %{
        stalled_starts: stalled_starts(locked, score),
        setup_failures: setup_failures(locked, score),
        progress_at_start: score,
        shutdown_stopped: false,
        isolating_row_id: nil
      })

    if counted.mode == :all_or_nothing and stalled_out?(counted),
      do: mark_finished(counted, {:failed, %{reason: :crashed}}),
      else: counted
  end

  # Rows that moved on count once, and once more when they finished, so a
  # row resolved in phase 1 raises the score as one applied in phase 2 does.
  defp progress_score(locked) do
    moved =
      row_resource()
      |> Ash.Query.filter(bulk_action_id == ^locked.id and status != :pending)
      |> BulkActionLock.pin()
      |> Ash.count!(authorize?: false)

    finished =
      row_resource()
      |> Ash.Query.filter(bulk_action_id == ^locked.id and status in [:succeeded, :failed])
      |> BulkActionLock.pin()
      |> Ash.count!(authorize?: false)

    moved + finished
  end

  defp stalled_starts(%{progress_at_start: nil}, _score), do: 0
  defp stalled_starts(%{progress_at_start: last}, score) when score > last, do: 0
  defp stalled_starts(%{shutdown_stopped: true, stalled_starts: stalled}, _score), do: stalled
  defp stalled_starts(%{stalled_starts: stalled}, _score), do: stalled + 1

  # Only progress clears them: a start that dies in its setup moves no row.
  defp setup_failures(%{progress_at_start: last}, score) when not is_nil(last) and score > last,
    do: 0

  defp setup_failures(%{setup_failures: failures}, _score), do: failures

  # The poller's shutdown killed the last run, so the row it was running
  # alone didn't stop it: that row gets its bump back, unless it has run
  # since. One statement, `attempts - 1` where it is above 0, so the count it
  # changes is the one committed, never one read before.
  defp give_back_if_shut_down(%{shutdown_stopped: true, isolating_row_id: row_id} = locked)
       when not is_nil(row_id) do
    row_resource()
    |> Ash.Query.filter(
      id == ^row_id and bulk_action_id == ^locked.id and status in [:pending, :resolved] and
        attempts > 0
    )
    |> Ash.bulk_update!(:bump_attempts, %{by: -1}, strategy: :atomic, authorize?: false)

    :ok
  end

  defp give_back_if_shut_down(_locked), do: :ok

  # Under the lock. Nothing a page shows, so nothing is announced.
  defp count_crashes!(locked, changes) do
    {:ok, counted, _notifications} =
      Ash.update(locked, changes,
        action: :count_crashes,
        authorize?: false,
        return_notifications?: true
      )

    counted
  end

  defp stalled_out?(bulk_action),
    do: bulk_action.stalled_starts >= AshBulkDurable.Core.config(:max_stalled_starts, 3)

  # The start that brought it to the limit: the passes after it, while none
  # makes progress, stay in isolation without saying so again.
  defp entered_isolation?(bulk_action),
    do: bulk_action.stalled_starts == AshBulkDurable.Core.config(:max_stalled_starts, 3)

  # Per row only: all or nothing fails instead.
  defp isolating?(bulk_action), do: bulk_action.mode == :per_row and stalled_out?(bulk_action)

  defp announce_isolation(bulk_action) do
    what =
      if bulk_action.mode == :per_row,
        do: "running its rows one at a time",
        else: "failing it, as all or nothing has no row to run alone"

    Logger.warning(
      "ash_bulk_durable: bulk action #{bulk_action.id} made no progress in its last " <>
        "#{bulk_action.stalled_starts} starts; #{what}"
    )

    :telemetry.execute(
      [:ash_bulk_durable, :isolation, :start],
      %{system_time: System.system_time(), stalled_starts: bulk_action.stalled_starts},
      %{bulk_action_id: bulk_action.id, mode: bulk_action.mode}
    )
  end

  # `[:ash_bulk_durable, :bulk_action, :start | :stop | :exception]`. The bulk action
  # reaches one terminal `mark_finished` per attempt, so the stop event's
  # status/reason are read from the fresh row after `drive/1` returns.
  defp drive_with_telemetry(bulk_action) do
    :telemetry.span(
      [:ash_bulk_durable, :bulk_action],
      bulk_action_start_metadata(bulk_action),
      fn ->
        try do
          drive(bulk_action)
        after
          Progress.forget(bulk_action.id)
        end

        {measurements, metadata} = bulk_action_stop(bulk_action)
        {:ok, measurements, metadata}
      end
    )
  end

  defp terminal?(status),
    do: status in [:completed, :completed_with_errors, :failed, :cancelled]

  defp drive(bulk_action) do
    case set_up(bulk_action) do
      {:ok, settings, downloaded} -> drive_rows(bulk_action, settings, downloaded)
      :busy -> :ok
    end
  end

  # Everything a run does after its start and before its first row. What
  # raises here raises again on every start, and moves no row, so neither
  # the stall count nor isolation would ever end it: it is counted instead.
  # A kill is not an exception, and is never counted here.
  defp set_up(bulk_action) do
    settings = Runner.settings(bulk_action, reconstruct_scope(bulk_action), %{})

    with :ok <- forget_lost_resolutions(bulk_action, settings),
         do: {:ok, settings, download_staged_files_with_telemetry(bulk_action, settings)}
  rescue
    error in RowMovedOnError ->
      reraise error, __STACKTRACE__

    error ->
      stacktrace = __STACKTRACE__
      count_setup_failure(bulk_action, error)
      reraise error, stacktrace
  end

  # Under the lock, in the run's pass. `:max_setup_failures` of them in a
  # row, with no progress between, fail the bulk action with the last
  # exception's message. A count that can't be written (the database down,
  # most likely) is logged, and the setup's own exception raised as before.
  defp count_setup_failure(bulk_action, error) do
    max = AshBulkDurable.Core.config(:max_setup_failures, 3)

    in_pass(bulk_action, fn locked ->
      counted = count_crashes!(locked, %{setup_failures: locked.setup_failures + 1})

      if counted.setup_failures >= max do
        Logger.error(
          "ash_bulk_durable: bulk action #{bulk_action.id} raised before reaching a row in " <>
            "#{counted.setup_failures} starts without progress; failing it: " <>
            Exception.message(error)
        )

        mark_finished(
          counted,
          {:failed, %{reason: :setup_error, message: Exception.message(error)}}
        )
      end
    end)
  rescue
    count_error ->
      Logger.error(
        "ash_bulk_durable: bulk action #{bulk_action.id} couldn't count its setup failure: " <>
          Exception.message(count_error)
      )
  end

  defp drive_rows(bulk_action, settings, downloaded) do
    terminal_bulk_action =
      case downloaded do
        {:ok, staged_paths} ->
          # A run stopped by a row that moved on raises past this.
          try do
            run_rows(bulk_action, %{settings | staged_files: staged_paths})
          after
            delete_local_staged_tmp(staged_paths)
          end

        {:error, reason} ->
          run_without_staged_files(bulk_action, settings, reason)
      end

    if terminal_bulk_action, do: maybe_delete_staging(terminal_bulk_action)
    :ok
  end

  # One transaction can't lose some rows, so all or nothing stops. Per row, a
  # row a resolver no longer has to reach for the files runs as it would.
  defp run_without_staged_files(%{mode: :all_or_nothing} = bulk_action, _settings, reason) do
    finish_locked(
      bulk_action,
      {:failed, %{reason: :staged_file_download_error, term: inspect(reason)}}
    )
  end

  defp run_without_staged_files(bulk_action, settings, reason) do
    Logger.error(
      "bulk action #{bulk_action.id} couldn't read its staged files: #{inspect(reason)}"
    )

    bulk_action
    |> pending_rows()
    |> Enum.filter(&Runner.resolver_pending?(settings, &1))
    |> Enum.each(&mark_row_failed(&1, %StagedFileError{}, settings.pass))

    run_rows(bulk_action, settings)
  end

  # Drives phase 1 + phase 2 and returns the terminal `BulkAction` from
  # the `:mark_finished` call that closed the attempt, or nil when another
  # transaction held the bulk action and this run stopped without one. That
  # fresh record is threaded back to `drive/2` so `maybe_delete_staging/1`
  # can act on it without a re-fetch window between the terminal write and
  # the purge decision.
  defp run_rows(bulk_action, settings) do
    with nil <- refused_row(bulk_action),
         :ok <- resolve_pending_rows(bulk_action, settings) do
      run_chunks(bulk_action, settings)
    else
      %{row_index: row_index, error: error} ->
        finish_locked(
          bulk_action,
          {:failed, atomic_failure_detail(:atomic_phase1_failed, error, row_index)}
        )

      {:atomic_phase1_failed, {row_index, err}} ->
        finish_locked(
          bulk_action,
          {:failed, atomic_failure_detail(:atomic_phase1_failed, err, row_index)}
        )

      {:prepare_failed, error} ->
        finish_locked(
          bulk_action,
          {:failed, %{reason: :resolver_prepare_error, term: inspect(error)}}
        )

      :busy ->
        nil
    end
  end

  # A row its caller refused before it was stored fails an all-or-nothing
  # bulk action before anything is resolved or written.
  defp refused_row(%{mode: :all_or_nothing} = bulk_action) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :failed)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp refused_row(_bulk_action), do: nil

  # ── Bulk action loading + scope rebuild ─────────────────────────────────────────

  defp fetch_bulk_action!(bulk_action_id) do
    Ash.get!(bulk_action_resource(), bulk_action_id, authorize?: false)
  end

  defp reconstruct_scope(bulk_action),
    do: AshBulkDurable.Core.Owner.scope_from_worker_key(bulk_action.user_id, bulk_action.tenant)

  defp mark_finished(bulk_action, result) do
    Ash.update!(bulk_action, %{result: result}, action: :mark_finished, authorize?: false)
  end

  # ── The bulk action lock ───────────────────────────────────────────────

  @writing {__MODULE__, :writing}
  @chunk_span {__MODULE__, :chunk_span}

  # Every lock a run takes after its start: only while the bulk action is in
  # the pass the run started (see "Passes" above). One a retry has moved on
  # reads as held, and the run stops.
  defp in_pass(run, fun, statuses \\ @runnable),
    do: locked(run.id, fun, statuses, Ash.Expr.expr(pass == ^run.pass))

  # Runs `fun` in a transaction of its own that first locks the bulk action
  # (`BulkActionLock`, `SKIP LOCKED`) while its status is one of `statuses`
  # and it matches `filter`, and gives it the locked record, taken from
  # `:queued` to `:running` if it was queued. Returns `{:ok, result}`;
  # `:busy`, nothing written, when another transaction holds the lock or the
  # bulk action's status is another, or it doesn't match `filter`;
  # or `{:rolled_back, writing, error}` when rows `write_rows/5` was
  # writing failed, which rolls back the whole transaction, `writing` being
  # what it was given to remember. Ash announces what the transaction wrote
  # once it commits. The run's ticker is held meanwhile, so its stamp never
  # holds the lock this transaction takes (see `Liveness.hold/1`).
  defp locked(bulk_action_id, fun, statuses, filter) do
    Process.delete(@writing)
    ticker = Process.get(@ticker)
    Liveness.hold(ticker)

    try do
      lock_and_run(bulk_action_id, fun, statuses, filter)
    after
      Liveness.release(ticker)
    end
  end

  defp lock_and_run(bulk_action_id, fun, statuses, filter) do
    Ash.transaction(
      [bulk_action_resource(), row_resource()],
      fn ->
        case BulkActionLock.lock(bulk_action_id, statuses, filter: filter) do
          {:ok, locked} -> {:ok, fun.(start_running(locked))}
          :none -> :busy
        end
      end
    )
    |> case do
      {:ok, result} ->
        Process.delete(@writing)
        result

      {:error, error} ->
        rolled_back(Process.delete(@writing), error, bulk_action_id)
    end
  end

  # A refused flip fails a batch like a row failure would, but it is not one:
  # another run wrote the row, so this one stops. Rolled back anywhere else,
  # the transaction raises as `Ash.update!/3` would.
  defp rolled_back(writing, error, bulk_action_id) do
    raise_if_moved_on!(error, bulk_action_id)
    if writing, do: {:rolled_back, writing, error}, else: raise(Ash.Error.to_error_class(error))
  end

  defp start_running(%{status: :queued} = locked),
    do: Ash.update!(locked, %{}, action: :mark_running, authorize?: false)

  defp start_running(locked), do: locked

  # A verdict written under the lock, read from the locked record: the
  # terminal bulk action, or nil when the lock was not taken.
  defp finish_locked(bulk_action, result, statuses \\ @runnable) do
    case in_pass(bulk_action, &mark_finished(&1, result), statuses) do
      {:ok, terminal} -> terminal
      :busy -> nil
    end
  end

  # ── Kept resolutions ───────────────────────────────────────────────────

  # A row left `:resolved` by a crash never reaches the resolve phase, and
  # a row that lost a file may be the only one needing the download: so what
  # rows lost while they waited is found here, before either. Asking storage
  # happens outside any transaction; the rows are put back under the lock,
  # each read again under it, and `:busy` stops the run.
  defp forget_lost_resolutions(bulk_action, settings) do
    row_resource()
    |> Ash.Query.filter(
      bulk_action_id == ^bulk_action.id and status in [:pending, :resolved] and
        resolved_data != ^%{}
    )
    |> Ash.read!(authorize?: false)
    |> then(&Runner.lost_resolutions(settings, &1))
    |> forget_locked(bulk_action)
  end

  defp forget_locked([], _bulk_action), do: :ok

  defp forget_locked(lost, bulk_action) do
    case in_pass(bulk_action, fn _locked -> forget_resolutions(lost, bulk_action.id) end) do
      {:ok, :ok} -> :ok
      :busy -> :busy
    end
  end

  # A row no longer `:pending` or `:resolved` under the lock has moved on
  # since it was read, and has nothing left to forget.
  defp forget_resolutions(lost, bulk_action_id) do
    ids = Enum.map(lost, fn {row, _names} -> row.id end)

    fresh =
      row_resource()
      |> Ash.Query.filter(id in ^ids and status in [:pending, :resolved])
      |> BulkActionLock.pin()
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1})

    Enum.each(lost, fn {row, names} ->
      with {:ok, row} <- Map.fetch(fresh, row.id) do
        row
        |> Ash.update(%{names: names}, action: :forget_resolutions, authorize?: false)
        |> row_flipped!(bulk_action_id)
      end
    end)
  end

  # ── Staged-file download ───────────────────────────────────────────────

  # `[:ash_bulk_durable, :staged_files_download, :stop]`. Wraps the storage→tmp
  # fetch so a download error also surfaces an `:exception` event.
  defp download_staged_files_with_telemetry(bulk_action, settings) do
    :telemetry.span(
      [:ash_bulk_durable, :staged_files_download],
      %{bulk_action_id: bulk_action.id},
      fn ->
        result = download_staged_files(bulk_action, settings)
        {measurements, metadata} = staged_files_download_stop(bulk_action.id, result)
        {result, measurements, metadata}
      end
    )
  end

  defp staged_files_download_stop(bulk_action_id, {:ok, paths}) do
    {%{file_count: map_size(paths), bytes_downloaded: total_staged_bytes(paths)},
     %{bulk_action_id: bulk_action_id}}
  end

  defp staged_files_download_stop(bulk_action_id, {:error, _reason}) do
    {%{file_count: 0, bytes_downloaded: 0}, %{bulk_action_id: bulk_action_id}}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp total_staged_bytes(paths) do
    Enum.reduce(paths, 0, fn {_field, path}, acc ->
      case File.stat(path) do
        {:ok, %{size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  # Keyed as they were staged, for the resolvers that read them.
  defp download_staged_files(%{staged_files: keys}, _settings) when map_size(keys) == 0,
    do: {:ok, %{}}

  # Only a resolver reads a staged file, and the engine can't tell which one
  # it reads: one row left to resolve downloads them all, and none downloads
  # none, so a retry that needs no file outlives the staging sweep.
  defp download_staged_files(bulk_action, settings) do
    if resolver_pending?(bulk_action, settings),
      do: fetch_staged_files(bulk_action.staged_files),
      else: {:ok, %{}}
  end

  defp resolver_pending?(bulk_action, settings) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :pending)
    |> Ash.stream!(authorize?: false, batch_size: 500, allow_stream_with: :offset)
    |> Enum.any?(&Runner.resolver_pending?(settings, &1))
  end

  defp pending_rows(bulk_action) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :pending)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_staged_files(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn {name, key}, {:ok, acc} ->
      case fetch_one_blob(key) do
        {:ok, tmp_path} ->
          {:cont, {:ok, Map.put(acc, name, tmp_path)}}

        {:error, term} ->
          {:halt, {:error, term}}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp fetch_one_blob(key) do
    case Storage.get_object(key) do
      {:ok, body} ->
        tmp = Briefly.create!(prefix: "ash_bulk_durable_")
        File.write!(tmp, body)
        {:ok, tmp}

      {:error, term} ->
        {:error, term}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp delete_local_staged_tmp(staged_paths) do
    Enum.each(staged_paths, fn {_name, path} -> File.rm(path) end)
  end

  # Acts on the terminal record returned by `mark_finished/2` (threaded
  # back through `drive/2` via `run_rows/3`). Re-reading the bulk action
  # here would reopen a window where another writer could land between the
  # terminal write and the purge decision, so the purge would key off a
  # status the worker never set.
  defp maybe_delete_staging(bulk_action) do
    if delete_staging?(bulk_action.status) do
      Enum.each(bulk_action.staged_files, fn {_name, key} -> Storage.delete_object(key) end)
    end

    :ok
  end

  # A `:failed` bulk action can be retried, so its files stay for the daily
  # sweep to reclaim.
  defp delete_staging?(:completed), do: true
  defp delete_staging?(:cancelled), do: true
  defp delete_staging?(_other), do: false

  # ── Phase 1: resolving references ──────────────────────────────────────

  # `[:ash_bulk_durable, :phase1, :start | :stop | :exception]`. Span
  # result is the status (`:ok` or `{:atomic_phase1_failed, err}`); resolved
  # vs failed counts ride the stop event's measurements.
  #
  # Only rows holding a reference are `:pending`; the per-row `:resolve`
  # action runs over each `:pending` chunk via `Task.async_stream`. The
  # resolution happens in `:resolve`'s `before_transaction` (outside any
  # transaction), bounded by `:phase1_concurrency`. NOTE: keep
  # `:phase1_concurrency` below the DB pool size — each in-flight resolve
  # takes a connection for its (short) write.
  defp resolve_pending_rows(bulk_action, settings) do
    concurrency = AshBulkDurable.Core.config(:phase1_concurrency, 4)
    to_resolve = pending_row_count(bulk_action)

    start_metadata = %{
      bulk_action_id: bulk_action.id,
      rows_to_resolve: to_resolve,
      concurrency: concurrency
    }

    if to_resolve > 0, do: Progress.resolving_started(bulk_action, to_resolve)

    :telemetry.span([:ash_bulk_durable, :phase1], start_metadata, fn ->
      {status, failed} = resolve_chunks(bulk_action, settings, concurrency)
      Progress.resolving_finished(bulk_action.id)
      measurements = %{rows_resolved: to_resolve - failed, rows_failed: failed}
      {status, measurements, %{bulk_action_id: bulk_action.id}}
    end)
  end

  # Chunk the `:pending` rows the same way phase 2 chunks `:resolved` rows.
  # Each chunk's rows resolve concurrently; a resolved row flips to
  # `:resolved`, leaving `:pending`, so the next read returns the next
  # slice — state mutation is the pagination. Returns `{status, failed}`.
  defp resolve_chunks(bulk_action, settings, concurrency) do
    atomic? = bulk_action.mode == :all_or_nothing
    do_resolve_chunks(bulk_action, settings, concurrency, atomic?, 0)
  end

  # An all-or-nothing bulk action is one chunk in one transaction, whatever
  # its `chunk_size`; that only sizes a per-row bulk action's batches.
  defp rows_per_chunk(%{mode: :all_or_nothing, total_rows: total_rows}), do: total_rows
  defp rows_per_chunk(%{mode: :per_row, chunk_size: chunk_size}), do: chunk_size

  # A row to run alone goes first, in a chunk of its own (see "Crashes"
  # above). Looked for outside the lock, as phase 1 reads, then taken under it.
  defp do_resolve_chunks(bulk_action, settings, concurrency, atomic?, failed_acc) do
    case next_alone_row(bulk_action, :pending) do
      nil -> resolve_next_chunk(bulk_action, settings, concurrency, atomic?, failed_acc)
      _row -> resolve_alone(bulk_action, settings, concurrency, atomic?, failed_acc)
    end
  end

  defp resolve_alone(bulk_action, settings, concurrency, atomic?, failed_acc) do
    case isolate_next(bulk_action, :pending) do
      {:alone, row} ->
        case resolve_chunk([row], settings, 1, atomic?) do
          {:ok, failed} ->
            do_resolve_chunks(bulk_action, settings, concurrency, atomic?, failed_acc + failed)

          {:prepare_failed, error} ->
            {{:prepare_failed, error}, failed_acc}
        end

      :crashed ->
        Progress.row_resolved(bulk_action.id)
        do_resolve_chunks(bulk_action, settings, concurrency, atomic?, failed_acc + 1)

      :none ->
        resolve_next_chunk(bulk_action, settings, concurrency, atomic?, failed_acc)

      :busy ->
        {:busy, failed_acc}
    end
  end

  defp resolve_next_chunk(bulk_action, settings, concurrency, atomic?, failed_acc) do
    chunk =
      row_resource()
      |> Ash.Query.for_read(:next_pending_chunk, %{
        bulk_action_id: bulk_action.id,
        chunk_size: rows_per_chunk(bulk_action)
      })
      |> not_alone(bulk_action)
      |> Ash.read!(authorize?: false)

    case chunk do
      [] ->
        {:ok, failed_acc}

      chunk ->
        case resolve_chunk(chunk, settings, concurrency, atomic?) do
          {:ok, failed} ->
            do_resolve_chunks(bulk_action, settings, concurrency, atomic?, failed_acc + failed)

          {:atomic_phase1_failed, err, failed} ->
            {{:atomic_phase1_failed, err}, failed_acc + failed}

          {:prepare_failed, error} ->
            {{:prepare_failed, error}, failed_acc}
        end
    end
  end

  # The chunk's tenants first: a row whose tenant can't be resolved fails
  # there. The rest resolve tenant by tenant, so a resolver is readied in the
  # tenant it resolves for.
  defp resolve_chunk(chunk, settings, concurrency, atomic?) do
    case Runner.resolve_tenants(settings, chunk) do
      {:ok, tenants} ->
        {tenanted, refused} =
          Enum.split_with(tenants, fn {_row, result} -> match?({:ok, _}, result) end)

        refused
        |> Enum.reduce_while({:ok, 0}, fn {row, result}, {status, failed} ->
          reduce_resolution(result, row, status, failed, settings, atomic?)
        end)
        |> resolve_tenant_groups(tenanted, settings, concurrency, atomic?)

      {:error, error} ->
        {:prepare_failed, error}
    end
  end

  defp resolve_tenant_groups({:ok, failed}, tenanted, settings, concurrency, atomic?) do
    tenanted
    |> Enum.group_by(fn {_row, {:ok, tenant}} -> tenant end, fn {row, _tenant} -> row end)
    |> Enum.reduce_while({:ok, failed}, fn {tenant, rows}, {:ok, failed} ->
      case resolve_group(rows, %{settings | tenant: tenant}, concurrency, atomic?) do
        {:ok, group_failed} ->
          {:cont, {:ok, failed + group_failed}}

        {:atomic_phase1_failed, err, group_failed} ->
          {:halt, {:atomic_phase1_failed, err, failed + group_failed}}

        {:prepare_failed, error} ->
          {:halt, {:prepare_failed, error}}
      end
    end)
  end

  defp resolve_tenant_groups(halted, _tenanted, _settings, _concurrency, _atomic?), do: halted

  # A group's resolvers are readied once for all its rows, and released
  # whatever the rows' outcome.
  defp resolve_group(rows, settings, concurrency, atomic?) do
    references = Runner.references(settings, rows)

    case Reference.prepare(references, Runner.resolver_context(settings)) do
      {:ok, resolvers} ->
        try do
          resolve_rows(rows, settings, resolvers, concurrency, atomic?)
        after
          Reference.finish(resolvers)
        end

      {:error, error, resolvers} ->
        Reference.finish(resolvers)
        {:prepare_failed, error}
    end
  end

  # The timeout runs per task, and an overrun kills only that task, so one
  # slow row fails alone. Left to the default it would exit this process,
  # where no rescue reaches, and every attempt would meet the same row.
  defp resolve_rows(rows, settings, resolvers, concurrency, atomic?) do
    timeout = AshBulkDurable.Core.config(:row_resolve_timeout, @row_resolve_timeout)

    rows
    |> Task.async_stream(
      fn row -> {row, resolve_one_row(row, settings, resolvers)} end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.reduce_while({:ok, 0}, fn
      {:ok, {row, result}}, {status, failed} ->
        reduce_resolution(result, row, status, failed, settings, atomic?)

      {:exit, {row, :timeout}}, {status, failed} ->
        error = Runner.row_timed_out(timeout, row)
        reduce_resolution({:error, error}, row, status, failed, settings, atomic?)
    end)
  end

  # Each row it is handed has been committed, resolved or failed, by the time
  # it is counted for a page (`Progress`).
  defp reduce_resolution({:ok, _resolved}, row, status, failed, _settings, _atomic?) do
    Progress.row_resolved(row.bulk_action_id)
    {:cont, {status, failed}}
  end

  defp reduce_resolution({:error, err}, row, _status, failed, settings, true) do
    raise_if_moved_on!(err, row.bulk_action_id)
    mark_row_failed(row, err, settings.pass)
    Progress.row_resolved(row.bulk_action_id)
    {:halt, {:atomic_phase1_failed, {row.row_index, err}, failed + 1}}
  end

  defp reduce_resolution({:error, err}, row, status, failed, settings, false) do
    raise_if_moved_on!(err, row.bulk_action_id)
    mark_row_failed(row, err, settings.pass)
    Progress.row_resolved(row.bulk_action_id)
    {:cont, {status, failed + 1}}
  end

  # One row through the `:resolve` action. The resolution happens in the
  # action's `before_transaction` hook (`AshBulkDurable.Core.Changes.ResolveRow`);
  # the settings, in the row's tenant, and the prepared resolvers ride in on
  # the context.
  defp resolve_one_row(row, settings, resolvers) do
    Ash.update(row, %{},
      action: :resolve,
      authorize?: false,
      context: %{
        ash_bulk_durable: %{settings: settings, resolvers: resolvers, pass: settings.pass}
      }
    )
  rescue
    exception -> Runner.row_raised(exception, __STACKTRACE__, row)
  end

  # ── Phase 2: chunk loop ────────────────────────────────────────────────

  # Each chunk runs in a transaction of its own that holds the bulk action
  # lock (`locked/2`): its rows are read under the lock, written, and the
  # verdict written in the same transaction once no row is left. Between
  # chunks nothing is held, so another run may take a turn; each reads what
  # the last committed. Returns the terminal bulk action, or nil when another
  # transaction held the lock and this run stopped.
  defp run_chunks(bulk_action, settings), do: run_chunks(bulk_action, settings, 0)

  defp run_chunks(bulk_action, settings, chunk_index) do
    case run_chunk(bulk_action, settings, chunk_index) do
      :continue -> run_chunks(bulk_action, settings, chunk_index + 1)
      {:done, terminal} -> terminal
      :busy -> nil
    end
  end

  # A chunk that fails rolls back its transaction and releases the lock, so
  # what follows (recovery, a rollback verdict) runs in transactions of its
  # own. A raise anywhere after the chunk started, its commit and a row that
  # moved on included, closes its telemetry span with `:exception`.
  defp run_chunk(bulk_action, settings, chunk_index) do
    case in_pass(bulk_action, &write_next_chunk(&1, settings, chunk_index)) do
      {:ok, {:done, terminal}} ->
        {:done, terminal}

      {:ok, {:written, span, notifications, terminal}} ->
        Ash.Notifier.notify(notifications)
        chunk_stop(span, chunk_measurements(span.rows, span.rows, 0, 1), :ok, :none)
        if terminal, do: {:done, terminal}, else: :continue

      {:rolled_back, {span, rows}, error} ->
        chunk_failed(bulk_action, settings, span, rows, error)

      {:ok, {:alone, row}} ->
        if elem(recover_row(row, settings, bulk_action), 0) == :busy,
          do: :busy,
          else: :continue

      {:ok, {:crashed, row}} ->
        report_crashed(row)
        :continue

      :busy ->
        :busy
    end
  rescue
    exception -> chunk_exception(exception, __STACKTRACE__)
  end

  # A row to run alone goes before the chunks (see "Crashes" above): this
  # transaction only bumps it, or fails it, and it runs in one of its own.
  defp write_next_chunk(locked, settings, chunk_index) do
    case isolate(locked, :resolved) do
      :none -> write_chunk(locked, settings, chunk_index)
      alone_or_crashed -> alone_or_crashed
    end
  end

  defp write_chunk(locked, settings, chunk_index) do
    case next_resolved_rows(locked, rows_per_chunk(locked)) do
      [] ->
        {:done, unless(rows_left?(locked), do: finalize_bulk_action(locked, 0))}

      rows ->
        span = chunk_start(locked, chunk_index, rows)

        notifications =
          write_rows(rows, settings, locked, {span, rows},
            stop_on_error?: locked.mode == :all_or_nothing
          )

        Liveness.stamp!(locked)
        {:written, span, notifications, finalize_if_last(locked, length(rows))}
    end
  end

  defp next_resolved_rows(locked, count) do
    row_resource()
    |> Ash.Query.for_read(:next_resolved_chunk, %{bulk_action_id: locked.id, chunk_size: count})
    |> not_alone(locked)
    |> BulkActionLock.pin()
    |> Ash.read!(authorize?: false)
  end

  # The verdict, in the transaction that wrote the last rows: none while a
  # row is left, whether for a chunk or to run alone.
  defp finalize_if_last(locked, written) do
    unless rows_left?(locked), do: finalize_bulk_action(locked, written)
  end

  # A `:pending` row left in phase 2 was put back by another run that lost
  # its resolutions (`forget_lost_resolutions/2`): that run resolves and
  # applies it, or the next start does, and writes the verdict then.
  defp rows_left?(locked) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^locked.id and status in [:pending, :resolved])
    |> BulkActionLock.pin()
    |> Ash.exists?(authorize?: false)
  end

  # From the locked record and what this transaction wrote since it read it,
  # which the record it returns (and announces) counts too.
  defp finalize_bulk_action(locked, written) do
    locked = %{locked | rows_done: locked.rows_done + written}

    final_status =
      if locked.rows_done == locked.total_rows,
        do: :completed,
        else: :completed_with_errors

    mark_finished(locked, final_status)
  end

  # All or nothing: the whole bulk action is one chunk, so any failure fails
  # it, with the verdict written under the lock again: unless another run
  # holds it, or finished the bulk action meanwhile. The run started it, so
  # only a running one matches.
  defp chunk_failed(%{mode: :all_or_nothing} = bulk_action, _settings, span, _rows, error) do
    terminal =
      finish_locked(
        bulk_action,
        {:failed,
         atomic_failure_detail(:atomic_chunk_rolled_back, error, error_row_index(error))},
        [:running]
      )

    chunk_stop(span, chunk_measurements(span.rows, 0, span.rows, 2), :rolled_back, :none)
    if terminal, do: {:done, terminal}, else: :busy
  end

  # Per row: the chunk rolled back (every row back to :resolved), so recover
  # its rows: good rows commit and only the bad ones land :failed.
  defp chunk_failed(bulk_action, settings, span, rows, _error) do
    recovering = %{
      bulk_action: bulk_action,
      settings: settings,
      min: AshBulkDurable.Core.config(:halving_min_rows, 8)
    }

    {status, tally} = recover(rows, recovering)

    chunk_stop(
      span,
      chunk_measurements(span.rows, tally.succeeded, tally.failed, 1 + tally.transactions),
      :rolled_back,
      tally.recovery
    )

    status
  end

  # ── Recovering a failed chunk ──────────────────────────────────────────

  # A chunk above `:halving_min_rows` is halved; one at or below it, or with
  # halving off (0), runs row by row. Either way rows commit in the order the
  # chunk read them, and each failing row is marked with the error it gave
  # running alone, so the rows that succeed, those that fail and their errors
  # are the ones row by row gives: only the number of transactions differs.
  # Returns `{:continue | :busy, tally}`; `:busy` stops the recovery, since
  # the run holding the lock reads these same rows and recovers them itself.
  defp recover(rows, recovering) do
    if recovering.min > 0 and length(rows) > recovering.min,
      do: halve(rows, nil, recovering, tally(:halving)),
      else: row_by_row(rows, recovering, tally(:row_by_row))
  end

  defp tally(recovery), do: %{succeeded: 0, failed: 0, transactions: 0, recovery: recovery}

  # `rows` just failed together, `error` being what they failed with. A single
  # row failed alone, with its own error, and is marked. A set at or below
  # `:halving_min_rows` runs row by row. A larger one splits in two, and each
  # half is tried in turn, the first recovered before the second is tried.
  defp halve([row], error, recovering, tally), do: mark_failed(row, error, recovering, tally)

  defp halve(rows, _error, %{min: min} = recovering, tally) when length(rows) <= min,
    do: row_by_row(rows, recovering, tally)

  defp halve(rows, _error, recovering, tally) do
    {first, second} = Enum.split(rows, div(length(rows), 2))

    case try_rows(first, recovering, tally) do
      {:ok, tally} ->
        second_half(second, :ok, recovering, tally)

      {:failed, fresh, error, before} ->
        with {:continue, tally} <- halve(fresh, error, recovering, before) do
          second_half(second, paid_off(fresh, before, tally), recovering, tally)
        end

      {:busy, tally} ->
        {:busy, tally}
    end
  end

  # Both halves failing hints at many bad rows, where halving costs more than
  # row by row: once halving the first half cost at least what row by row
  # would have (a run alone for each row, and a mark for each that failed),
  # the second goes row by row. So many bad rows cost little more than row by
  # row, while a few spread across both halves are still halved.
  defp second_half(rows, first, recovering, tally) do
    case try_rows(rows, recovering, tally) do
      {:failed, [_, _ | _] = fresh, _error, tally} when first == :not_paid_off ->
        row_by_row(fresh, recovering, %{tally | recovery: :row_by_row})

      {:failed, fresh, error, tally} ->
        halve(fresh, error, recovering, tally)

      {:ok, tally} ->
        {:continue, tally}

      {:busy, tally} ->
        {:busy, tally}
    end
  end

  defp paid_off(rows, before, tally) do
    spent = tally.transactions - before.transactions
    row_by_row = length(rows) + tally.failed - before.failed
    if spent < row_by_row, do: :paid_off, else: :not_paid_off
  end

  # One locked transaction runs `rows` together: those still `:resolved`
  # under the lock, the rest dropped (another run applied them, or a retry
  # reopened them). `{:ok, tally}` once they committed, or none was left;
  # `{:failed, fresh, error, tally}` when they rolled back, `fresh` being the
  # rows it ran.
  defp try_rows(rows, recovering, tally) do
    tally = %{tally | transactions: tally.transactions + 1}

    case in_pass(recovering.bulk_action, &write_together(&1, rows, recovering.settings)) do
      {:ok, :skipped} ->
        {:ok, tally}

      {:ok, {written, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, %{tally | succeeded: tally.succeeded + written}}

      {:rolled_back, fresh, error} ->
        {:failed, fresh, error, tally}

      :busy ->
        {:busy, tally}
    end
  end

  defp write_together(locked, rows, settings) do
    locked = Enum.reduce(rows, locked, &stop_isolating(&2, &1))

    case still_resolved_rows(rows) do
      [] -> :skipped
      fresh -> {length(fresh), write_rows(fresh, settings, locked, fresh, stop_on_error?: false)}
    end
    |> stamped(locked)
  end

  defp still_resolved_rows(rows) do
    ids = Enum.map(rows, & &1.id)

    row_resource()
    |> Ash.Query.filter(id in ^ids and status == :resolved)
    |> Ash.Query.sort(row_index: :asc)
    |> BulkActionLock.pin()
    |> Ash.read!(authorize?: false)
  end

  defp mark_failed(row, error, recovering, tally) do
    tally = %{tally | transactions: tally.transactions + 1}

    case mark_failed_locked(row, error, recovering.bulk_action) do
      :failed -> {:continue, %{tally | failed: tally.failed + 1}}
      :skipped -> {:continue, tally}
      :busy -> {:busy, tally}
    end
  end

  # Each row runs alone in a locked transaction of its own, and a row that
  # still fails is marked in a further one. A row no longer `:resolved` when
  # read under the lock was run by another run meanwhile, and is skipped.
  defp row_by_row(rows, recovering, tally) do
    Enum.reduce_while(rows, {:continue, tally}, fn row, {:continue, tally} ->
      {outcome, transactions} = recover_row(row, recovering.settings, recovering.bulk_action)
      tally = %{tally | transactions: tally.transactions + transactions}

      case outcome do
        :succeeded -> {:cont, {:continue, %{tally | succeeded: tally.succeeded + 1}}}
        :failed -> {:cont, {:continue, %{tally | failed: tally.failed + 1}}}
        :skipped -> {:cont, {:continue, tally}}
        :busy -> {:halt, {:busy, tally}}
      end
    end)
  end

  # How the row went, and the locked transactions it took.
  defp recover_row(row, settings, bulk_action) do
    case in_pass(bulk_action, &write_row_alone(&1, row, settings)) do
      {:ok, :skipped} ->
        {:skipped, 1}

      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        {:succeeded, 1}

      {:rolled_back, row, error} ->
        {mark_failed_locked(row, error, bulk_action), 2}

      :busy ->
        {:busy, 1}
    end
  end

  # A row run alone is no longer being isolated once this transaction, or the
  # one marking it failed, commits how it went.
  defp write_row_alone(locked, row, settings) do
    locked = stop_isolating(locked, row)

    case still_resolved(row) do
      nil -> :skipped
      fresh -> write_rows([fresh], settings, locked, fresh, stop_on_error?: false)
    end
    |> stamped(locked)
  end

  defp still_resolved(row) do
    row_resource()
    |> Ash.Query.filter(id == ^row.id and status == :resolved)
    |> BulkActionLock.pin()
    |> Ash.read_one!(authorize?: false)
  end

  defp stop_isolating(%{isolating_row_id: row_id} = locked, %{id: row_id}),
    do: count_crashes!(locked, %{isolating_row_id: nil})

  defp stop_isolating(locked, _row), do: locked

  # Only while the row, read again under the lock, is still `:resolved`: one
  # another run ran, or a retry reopened, since its own transaction rolled
  # back is skipped.
  defp mark_failed_locked(row, error, bulk_action) do
    case in_pass(bulk_action, fn locked -> mark_if_resolved(locked, row, error) end) do
      {:ok, :skipped} -> :skipped
      {:ok, _row} -> :failed
      :busy -> :busy
    end
  end

  defp mark_if_resolved(locked, row, error) do
    locked = stop_isolating(locked, row)

    case still_resolved(row) do
      nil -> :skipped
      fresh -> mark_row_failed(fresh, error)
    end
    |> stamped(locked)
  end

  # Isolation and recovery go from one locked transaction to the next, so
  # the ticker, held through each of them, misses nearly every tick: each of
  # them stamps instead, last, so the stamp is as fresh as its commit (see
  # `AshBulkDurable.Core.Liveness`). A transaction that rolls back never
  # gets here, and the one that follows it stamps.
  defp stamped(result, locked) do
    Liveness.stamp!(locked)
    result
  end

  # Drives the `:run` action over a batch of Rows, inside the locked
  # transaction. The settings and the locked bulk action ride in on the
  # action context so the change doesn't rebuild them per chunk. Returns what
  # the batch would announce, to send once the transaction commits. A failed
  # batch rolls back the whole transaction, and with it anything the
  # transaction would return, so `writing` is kept aside for `locked/2` to
  # hand back.
  defp write_rows(rows, settings, locked, writing, opts) do
    Process.put(@writing, writing)

    result =
      Ash.bulk_update(
        rows,
        :run,
        %{},
        [
          strategy: :stream,
          transaction: :all,
          return_records?: true,
          return_errors?: true,
          return_notifications?: true,
          authorize?: false,
          context: %{ash_bulk_durable: %{settings: settings, bulk_action: locked}}
        ] ++ opts
      )

    case result.status do
      :success ->
        Process.delete(@writing)
        result.notifications || []

      _failed ->
        Ash.DataLayer.rollback(bulk_action_resource(), first_error(result))
    end
  end

  defp first_error(%{errors: [error | _]}), do: error
  defp first_error(_result), do: :unknown

  # `[:ash_bulk_durable, :chunk, :start | :stop | :exception]`, as
  # `:telemetry.span/3` would emit them, but split: a chunk starts once its
  # rows are read under the lock, and stops after its transaction commits,
  # or after its recovery.
  defp chunk_start(locked, chunk_index, rows) do
    start = System.monotonic_time()

    metadata = %{
      bulk_action_id: locked.id,
      chunk_index: chunk_index,
      rows_in_chunk: length(rows),
      telemetry_span_context: make_ref()
    }

    :telemetry.execute(
      [:ash_bulk_durable, :chunk, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      metadata
    )

    span = %{start: start, metadata: metadata, rows: length(rows)}
    Process.put(@chunk_span, span)
    span
  end

  defp chunk_stop(span, measurements, outcome, recovery) do
    Process.delete(@chunk_span)
    stop = System.monotonic_time()

    :telemetry.execute(
      [:ash_bulk_durable, :chunk, :stop],
      Map.merge(measurements, %{duration: stop - span.start, monotonic_time: stop}),
      %{
        bulk_action_id: span.metadata.bulk_action_id,
        chunk_index: span.metadata.chunk_index,
        outcome: outcome,
        recovery: recovery,
        telemetry_span_context: span.metadata.telemetry_span_context
      }
    )
  end

  defp chunk_exception(exception, stacktrace) do
    case Process.delete(@chunk_span) do
      nil ->
        :ok

      span ->
        stop = System.monotonic_time()

        :telemetry.execute(
          [:ash_bulk_durable, :chunk, :exception],
          %{duration: stop - span.start, monotonic_time: stop},
          Map.merge(span.metadata, %{kind: :error, reason: exception, stacktrace: stacktrace})
        )
    end

    reraise exception, stacktrace
  end

  # An all-or-nothing failure names the first offending row (0-based, when
  # identifiable) and keeps its error, so the progress panel can tell the
  # user what to fix, not just that the bulk action rolled back.
  defp atomic_failure_detail(reason, error, row_index) do
    detail = %{reason: reason, error: error}
    if row_index, do: Map.put(detail, :row_index, row_index), else: detail
  end

  # `Ash.bulk_update` surfaces a failed row as the errored *target*
  # changeset (the target's create or update built by
  # `Runner.run_row/2`), which carries its row index on
  # the context. A Row changeset (a target that couldn't be read, or a
  # failed status flip) carries it on `data` instead. Splode error classes (`Ash.Error.Invalid`,
  # `Ash.Error.Unknown`, …) often arrive with a nil top-level changeset
  # but their nested `:errors` carry the originating changeset — walk the
  # list rather than falling through to nil.
  defp error_row_index(%Ash.Changeset{context: %{ash_bulk_durable: %{row_index: row_index}}}),
    do: row_index

  defp error_row_index(%Ash.Changeset{data: %{row_index: row_index}}), do: row_index
  defp error_row_index(%{changeset: %Ash.Changeset{} = changeset}), do: error_row_index(changeset)

  defp error_row_index(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &error_row_index/1)

  defp error_row_index(_error), do: nil

  defp chunk_measurements(rows_in_chunk, succeeded, failed, transactions) do
    %{
      rows_in_chunk: rows_in_chunk,
      rows_succeeded: succeeded,
      rows_failed: failed,
      transactions: transactions
    }
  end

  # ── Rows run alone ─────────────────────────────────────────────────────

  # Takes the next row to run alone, in a locked transaction of its own:
  # `{:alone, row}` once its bump has committed, `:crashed` once it has
  # failed as crashed, `:none` when no row is left to run alone, or `:busy`.
  defp isolate_next(bulk_action, in_status) do
    case in_pass(bulk_action, &isolate(&1, in_status)) do
      {:ok, {:crashed, row}} ->
        report_crashed(row)
        :crashed

      {:ok, result} ->
        result

      :busy ->
        :busy
    end
  end

  # Under the lock: the next row to run alone, read under it, bumped and
  # named as the row this run is isolating, or failed when it has stopped
  # the worker too often already.
  defp isolate(locked, in_status) do
    max_attempts = AshBulkDurable.Core.config(:max_row_attempts, 2)

    case next_alone_row(locked, in_status) do
      nil ->
        :none

      %{attempts: attempts} = row when attempts >= max_attempts ->
        crashed = mark_row_failed(row, %CrashedRowError{attempts: attempts})
        Liveness.stamp!(locked)
        {:crashed, crashed}

      row ->
        bumped =
          row
          |> Ash.Changeset.for_update(:bump_attempts, %{}, authorize?: false)
          |> Ash.Changeset.filter(Ash.Expr.expr(status == ^in_status))
          |> Ash.update(authorize?: false)
          |> row_flipped!(locked.id)

        locked
        |> count_crashes!(%{isolating_row_id: row.id})
        |> Liveness.stamp!()

        {:alone, bumped}
    end
  end

  # In isolation every row runs alone; otherwise only a suspect, one a run
  # died on while running it alone. All or nothing has no row to run alone.
  defp next_alone_row(%{mode: :all_or_nothing}, _in_status), do: nil

  defp next_alone_row(bulk_action, in_status) do
    query =
      Ash.Query.filter(
        row_resource(),
        bulk_action_id == ^bulk_action.id and status == ^in_status
      )

    if(isolating?(bulk_action), do: query, else: Ash.Query.filter(query, attempts > 0))
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.Query.limit(1)
    |> BulkActionLock.pin()
    |> Ash.read_one!(authorize?: false)
  end

  # The chunks leave out a row to run alone. Belt and braces: each chunk is
  # read only once no row to run alone is left (`isolate/2` under the same
  # lock in phase 2, the look first in phase 1).
  defp not_alone(query, %{mode: :per_row}), do: Ash.Query.filter(query, attempts == 0)
  defp not_alone(query, _bulk_action), do: query

  defp report_crashed(row) do
    Logger.error(
      "ash_bulk_durable: bulk action #{row.bulk_action_id}: row #{row.row_index} " <>
        "(#{row.id}) stopped the worker #{row.attempts} times; failed it as crashed"
    )

    :telemetry.execute(
      [:ash_bulk_durable, :row, :crashed],
      %{attempts: row.attempts},
      %{bulk_action_id: row.bulk_action_id, row_id: row.id, row_index: row.row_index}
    )
  end

  # ── Row mutators ───────────────────────────────────────────────────────

  # Best-effort row-by-row recovery (and phase-1 resolution) mark failures
  # here, *outside* the row's own (rolled-back) `:run` transaction. The success
  # path — target write + `:succeeded` flip + `rows_done` bump — lives in the
  # `:run` action's after_batch (`AshBulkDurable.Core.Changes.RunRow`).
  #
  # Phase 1 marks a row outside the lock, so it gives the run's `pass`: the
  # flip then matches only while the row is still on it (`RequireStatus`),
  # and one a retry has reopened onto the next stops the run. Under the
  # lock the pass is already checked, and none is given.
  defp mark_row_failed(row, err, pass \\ nil) do
    context = if pass, do: %{ash_bulk_durable: %{pass: pass}}, else: %{}

    row
    |> Ash.update(%{error: err}, action: :mark_failed, authorize?: false, context: context)
    |> row_flipped!(row.bulk_action_id)
  end

  # A row status flip another run's write refused stops the run; any other
  # error raises as `Ash.update!/3` would.
  defp row_flipped!({:ok, row}, _bulk_action_id), do: row

  defp row_flipped!({:error, error}, bulk_action_id) do
    raise_if_moved_on!(error, bulk_action_id)
    raise Ash.Error.to_error_class(error)
  end

  defp raise_if_moved_on!(error, bulk_action_id) do
    if row_moved_on?(error), do: raise(RowMovedOnError, bulk_action_id: bulk_action_id)
    :ok
  end

  # True only for the row resource's own `StaleRecord`: a status flip's
  # compare-and-set refused (`RequireStatus`). A target's `StaleRecord` is an
  # ordinary row failure.
  defp row_moved_on?(%Ash.Error.Changes.StaleRecord{resource: resource}),
    do: resource == row_resource()

  defp row_moved_on?(%Ash.Changeset{errors: errors}), do: row_moved_on?(errors)
  defp row_moved_on?(%{errors: errors}) when is_list(errors), do: row_moved_on?(errors)
  defp row_moved_on?(errors) when is_list(errors), do: Enum.any?(errors, &row_moved_on?/1)
  defp row_moved_on?(_error), do: false

  # ── Telemetry ────────────────────────────────────────────────────

  # Emitted before any write, so the attempt is observable even if the
  # bulk action never starts. `pending_rows_at_start == total_rows` is a cold
  # start; a smaller count is a resume.
  defp emit_worker_attempt_start(bulk_action) do
    :telemetry.execute(
      [:ash_bulk_durable, :worker_attempt, :start],
      %{system_time: System.system_time()},
      %{
        bulk_action_id: bulk_action.id,
        pending_rows_at_start: pending_row_count(bulk_action)
      }
    )
  end

  defp bulk_action_start_metadata(bulk_action) do
    %{
      bulk_action_id: bulk_action.id,
      user_id: bulk_action.user_id,
      resource_name: bulk_action.resource_name,
      action_name: bulk_action.action_name,
      total_rows: bulk_action.total_rows,
      chunk_size: bulk_action.chunk_size,
      mode: bulk_action.mode
    }
  end

  defp bulk_action_stop(bulk_action) do
    fresh = Ash.get!(bulk_action_resource(), bulk_action.id, authorize?: false)

    measurements = %{rows_done: fresh.rows_done, rows_failed: failed_row_count(fresh.id)}

    metadata = %{
      bulk_action_id: fresh.id,
      status: fresh.status,
      failure_reason: failure_reason(fresh)
    }

    {measurements, metadata}
  end

  defp failure_reason(%{status: status}) when status != :failed, do: nil
  defp failure_reason(%{result: %{"reason" => reason}}), do: reason_atom(reason)
  defp failure_reason(_run), do: nil

  # Map the serialized `result["reason"]` string back to its atom. Explicit
  # clauses (no `String.to_atom/1`) keep this to the known failure set — an
  # unrecognized reason yields nil rather than minting a new atom.
  defp reason_atom("resolver_prepare_error"), do: :resolver_prepare_error
  defp reason_atom("atomic_phase1_failed"), do: :atomic_phase1_failed
  defp reason_atom("atomic_chunk_rolled_back"), do: :atomic_chunk_rolled_back
  defp reason_atom("staged_file_download_error"), do: :staged_file_download_error
  defp reason_atom("crashed"), do: :crashed
  defp reason_atom(_reason), do: nil

  defp pending_row_count(bulk_action) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :pending)
    |> Ash.count!(authorize?: false)
  end

  defp failed_row_count(bulk_action_id) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id and status == :failed)
    |> Ash.count!(authorize?: false)
  end

  # ── Resource lookups ───────────────────────────────────────────────────

  defp bulk_action_resource, do: AshBulkDurable.Core.config(:bulk_action_resource)
  defp row_resource, do: AshBulkDurable.Core.config(:row_resource)
end
