# Changelog

## Unreleased

- First version: durable bulk actions kept as `BulkAction` and `Row`
  records, with per-row and all-or-nothing modes, retries, a sheet layer for
  CSV and XLSX, and an errors sheet to correct and upload again.
- Bulk actions are run by `Core.Poller`, one per node in the host's
  supervision tree, with no job queue: the `bulk_actions` table is the only
  record of what needs running. Every `:poll_interval`, and when a bulk
  action is submitted or retried on its node, it starts up to `:max_running`
  runs (`Worker.run/2`) in tasks: bulk actions `:queued`, or `:running` with a
  liveness hint (`alive_at`, on the database's clock) older than
  `:stale_after`, oldest first. A run stamps the hint when it starts, in every
  chunk it commits, and from a ticker every `:alive_interval`; the hint only
  decides when to start a run, never whether a write is allowed. A bulk
  action whose node died resumes from its rows on another node, instead of
  failing. The poller also runs the staged-file sweep every
  `:staging_sweep_interval`, and on shutdown gives its runs `:shutdown_grace`
  to finish before killing them.
- `example/`: a Phoenix app with a `/bulk` page to copy, using no other library
  for its screens: organizations and roles a worker acts under, and files in a
  sheet.
- The engine's tests at the root, the screens' tests in `example/`, and CI over
  both.
- Row status flips are compare-and-set: `:resolve`, `:mark_succeeded`,
  `:mark_failed` and `:forget_resolutions` match a row only while its status
  is one they may move it from, and are refused as `StaleRecord` otherwise. A
  run whose row moved on under another run of the same bulk action stops
  without writing anything more, and the other run carries on.
- `retry/2` and `retry_row/2` lock the bulk action (`FOR NO KEY UPDATE SKIP
  LOCKED`, through the new `Core.BulkActionLock`) before reading or writing
  any of its rows, and read the rows and the bulk action's status under that
  lock. A retry while another transaction holds the bulk action, or by a
  caller who doesn't own it, is refused at once with the usual `StaleRecord`,
  before reading any row.
- The worker runs each chunk in a transaction that first locks the bulk
  action, reads its rows under that lock, and writes the verdict in the same
  transaction once no row is left. Every verdict is written under the lock,
  and per-row recovery runs each row in a locked transaction of its own. A
  run that finds the bulk action locked stops at once, writing nothing, so two
  runs of one bulk action take turns rather than both writing it. A run
  starts in a short locked transaction of its own before phase 1, which marks
  the bulk action `:running`; a run that finds it locked there stops before
  resolving anything. Every target must live in the bulk action's repo.
- Staged files: a `:failed` bulk action keeps its staged files for a day
  from when it failed (`finished_at`), not from when they were uploaded, so
  its owner can still retry it after a run that stayed queued or running for a
  day. Abandoning a bulk action deletes its staged files itself once the
  cancel commits; inside a caller's own transaction, or when storage fails, it
  leaves them to the daily sweep. `PurgeStaleStaging.sweep/0` and
  `delete_staging/1` are public.
- `Worker.run_now/1` and `Worker.drain/0` run bulk actions in the calling
  process, for a host's tests and scripts: `run_now/1` runs one, `drain/0`
  every queued or running bulk action, oldest first, each at most once per
  call, returning how many it ran. The run itself is `Worker.run/2`, a plain
  function.
- A run that dies without returning (killed, out of memory, a NIF crash) no
  longer loops forever. Each start scores the bulk action's progress and
  counts the starts that made none (`stalled_starts`). At
  `:max_stalled_starts` (3) a per-row bulk action runs its rows alone, each
  row's `attempts` committed before it runs, and a row that has stopped the
  worker `:max_row_attempts` times (2) fails alone with
  `Core.CrashedRowError` while the rest run on; an all-or-nothing one fails
  with reason `:crashed`. A run the poller kills at shutdown is not counted.
- `abandon/2` writes `:cancelled` under the bulk action lock, like every
  other verdict: one whose lock another transaction holds, such as a retry's,
  is refused at once, and one its caller doesn't own is refused before
  anything is written. It deletes the staged files itself once its own
  transaction commits, as before.
- A retry bumps the bulk action's new `pass` column, and a run acts only on
  the pass it started: a run that outlived a verdict and a retry stops at its
  next lock instead of applying the new pass's rows with the old shared
  input. The verdict waits until no row is `:pending` or `:resolved`, and
  lost resolutions are put back under the lock. Every read made under the
  lock goes to the mutate repo, never a read replica.
- Rows have a `pass` column too, and phase 1's row writes check it: a run's
  `:resolve`, and its `:mark_failed` of a row that failed to resolve or lost
  its staged files, match the row only while the row's `pass` is the run's
  (`RequireStatus`, given the pass in the action context). A retry writes
  its new pass onto every row it reopens, in the transaction that bumps the
  bulk action's, so a run still in phase 1 when a retry reopens its row
  stops instead of resolving it with the old shared input. A write given no
  pass, such as a host's own, checks its status alone. A host that defines
  its own `:reopen_with_corrections` or `:enqueue_retry` must accept the new
  `pass` argument and set `pass` from it, or every retry fails.
- A per-row chunk that fails with returned errors is recovered by halving
  its rows instead of running each alone: a half that succeeds commits, one
  that fails splits again, and a single row that fails is marked as before.
  One bad row among 64 takes 16 transactions instead of 66. Sets at or
  below `:halving_min_rows` (8; 0 turns halving off) run row by row, and so
  does a second half once halving its failed first half didn't pay, so many
  bad rows cost little more than before. The rows that succeed, those that
  fail and their errors are the same. The chunk `:stop` event's `recovery`
  is now `:halving` or `:row_by_row`, and it measures `transactions`.
- Progress hints for the stretches a run commits nothing to its bulk action
  (`Core.Progress`): phase 1 broadcasts `"progress"` with `phase: :resolving`
  as rows resolve or fail, and an all-or-nothing write broadcasts it with
  `phase: :writing, committed: false` as each slice of its one transaction
  runs. They go out on `"bulk_action:<id>"` through `:pubsub_module`, carry
  the run's `pass`, are throttled to one per `:progress_interval` (a second
  by default; phase 1's last is always sent), never block or fail a run, and
  also run as `[:ash_bulk_durable, :phase1 | :all_or_nothing, :progress]`
  telemetry. The example's panel shows them.
