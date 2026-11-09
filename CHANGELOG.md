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
  to finish before killing them, clearing a killed run's hint so the next
  poll on any node resumes it.
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
- A bulk action whose resource or action no longer exists (renamed or
  removed by a deploy) is failed with `reason: :gone`, under the bulk action
  lock. Before, every run of it raised before reaching a row, and a per-row
  one was restarted forever with its owner unable to abandon, retry or submit
  again.
- A run that raises after its start and before its first row (the owner's
  scope, the runner's settings, storage) counts the exception in
  `setup_failures`, under the lock, and the `:max_setup_failures`th with no
  progress between (3 by default) fails the bulk action with
  `reason: :setup_error` and the exception's message. Kills are never
  counted, and progress or a retry clears the count. Before, a per-row one
  was restarted every `:stale_after` forever.
- A start that finds its bulk action `:gone` or `:unreadable` counts a setup
  failure too, running nothing, instead of failing it at once, and the
  `:max_setup_failures`th fails it with that reason. Both answers come from
  the node's own code, so during a rolling deploy a node still on the old
  release failed what only the new release could run; now the next start
  comes a `:stale_after` later, maybe on an upgraded node.
- An XLSX is read with calamine, a Rust library, through the `spreadsheet`
  package's precompiled NIF, instead of shelling out to csvkit's `in2csv`, so
  no Python is needed. Booleans read as `true`/`false` (they read `True`,
  which Ash refused), large numbers keep their digits instead of an exponent,
  a date in any custom format reads as a date, and a workbook with a dropdown
  list no longer gets a Python warning in its header row. `read_sheet/2`
  takes `:sheet`, a name or 0-based index among the visible sheets, and
  `:max_cells`, the rows × columns it reads at most (5,000,000 by default),
  and returns `{:error, {:too_many_cells, max_cells}}`, `{:error,
  {:unknown_sheet, sheet}}` or `{:error, {:xlsx, reason}}`. The reader is an `AshBulkDurable.Sheet.ExcelReader` behaviour,
  chosen with `config :ash_bulk_durable, excel_reader: ...`;
  `AshBulkDurable.Sheet.ExcelReader.Calamine` is the default and, for now,
  the only one.
- A resolver that throws or exits, or whose task dies (a process linked to
  it crashed, or it was killed alone), fails its row at once with
  `Core.RowExitError`, which says what it threw or why it exited, as a raise
  does. Before, it stopped the run, and the row failed only starts later, as
  crashed. Phase 1 runs its tasks unlinked, under a supervisor linked to the
  run, so they still go when the run does.
- A retry of a `:failed` bulk action while its owner has another unresolved
  one is refused with `{:error, %{unresolved: id}}`, that one's id, with
  nothing written, also when that one was submitted while the retry ran.
  Before, it failed with the one-unresolved index's unique-constraint
  error. A retried bulk action is `:queued`, not `:running`, until a run
  starts it; that run sets `started_at` again. A host's own
  `:enqueue_retry` should set `:queued` too.
- A failed bulk action whose staged files the daily sweep took can be
  finished with them again: `retry/2` and `retry_row/2` take
  `:staged_files`, which replace every file the bulk action held, and a
  retry with a corrected sheet takes `:companions`, checked as the sheet
  verbs check theirs. `abandon/2` also takes a `:failed` bulk action, and
  deletes its staged files at once. A host that defines its own
  `:enqueue_retry` needs a `staged_files` argument only to stage files again.
- `AshBulkDurable.Core.Storage` is worded as what the core wants done, not
  as S3 operations, and the worker no longer reads a staged file into
  memory: `get_object/1` is `fetch_file(key, path, opts)`, which writes the
  file to a temporary path the worker hands over; `delete_object/1` is
  `delete_file(key, opts)` and `list_objects/1` is `list_files(prefix, opts)`.
  The core passes empty `opts` today. A host's store renames its callbacks
  and writes the file instead of returning its bytes.
- `example/`: the `/bulk` page's retry zone takes the files a bulk action's
  mapping needs again, beside the corrected sheet, and says when a `:failed`
  one's files may be gone (it failed more than a day ago). A `:failed` bulk
  action gets an "Abandon bulk action" button.
- The daily sweep deletes a bulk action's staged files only under its lock,
  once its status still lets them go, so a retry that reopens a `:failed`
  bulk action past its day while the sweep runs keeps the files it still
  points at. Before, the sweep judged it by the status it read first and
  could delete them under the retry. A retry or abandon that comes while the
  sweep holds the lock is refused, as while any other transaction holds it.
- A sheet whose shape hides a mistake is refused instead of read with cells
  lost: two columns under one header return `{:error, {:duplicate_headers,
  headers}}` (blank headers may repeat), and a row with a filled cell past
  the last named header `{:error, {:extra_cells, row}}`, `row` being its
  number in the file. Blank headers after the last named one are dropped,
  and blank cells under them, such as a trailing comma's, are still fine.
  Blank rows above the header are skipped. Applies to CSV and XLSX;
  `ExcelReader.Calamine` now keeps blank rows, so an XLSX row's number is
  its row in the sheet.
- A chunk whose write meets the database's own trouble (a dropped
  connection, a deadlock or serialization failure, a lock or statement
  timeout, the server shutting down or out of resources:
  `Core.Transient`) no longer fails rows with it. The run raises, its rows
  stay `:resolved`, and the next start runs them. Before, recovery failed
  each such row with the database's message, and its owner had to retry it
  by hand. A lock timeout on the row's own write arrives from AshPostgres
  as `Ash.Error.Invalid.Unavailable`, and counts too. A host's own raise,
  however it is worded, still fails its row.
- `example/`: the `/bulk` page refuses a sheet `read_sheet/2` can't read
  instead of crashing, in the submit form and in the retry zone. It says
  why in terms the user can fix (which headers repeat, which row has a cell
  past the last header, the sheet is too large or missing, the file isn't a
  readable spreadsheet or CSV), and the next file uploads as usual. Any
  other failure to read the upload is logged, and the user is asked to try
  again. In the retry zone a refused sheet drops a corrected sheet staged
  before it, so "Retry failed rows" goes back to disabled.
- `AshBulkDurable.Storage.Local` is a `Core.Storage` that keeps staged files
  on the server's disk under a configured `:root` (or `:root` in each call's
  opts), for an app on one node or on several sharing a volume. It fetches,
  deletes and lists, and `put_file/3` stages a file, copied beside its
  destination and renamed in. Deleting a file removes the directories it
  leaves empty, up to `:root`, so the sweep's listing doesn't grow with
  every bulk action staged. A key that could reach outside `:root`
  (absolute, empty, an empty, `.` or `..` segment, a backslash, a NUL, or
  invalid UTF-8) is refused with `{:error, :unsafe_key}`, and a missing or
  empty `:root` raises. `use AshBulkDurable.Storage.Local` delegates the
  callbacks and `put_file/3`, overridable, for a host module that adds its
  own functions, and passes the options given to `use` (a `:root`, say) to
  each of them; the example's `LocalStorage` is one, and its root moves from
  `config :example, :storage_dir` to the store's `:root`.
- `Core.Storage` has an optional `check_config/1`, and `Core.Poller`
  refuses to start when the configured store answers `{:error, message}`,
  so a node without a disk store's `:root` fails at boot rather than at its
  first sweep or fetch.
