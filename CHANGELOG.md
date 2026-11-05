# Changelog

## Unreleased

- First version: durable bulk actions on Oban, kept as `BulkAction` and `Row`
  records, with per-row and all-or-nothing modes, retries, a sheet layer for
  CSV and XLSX, and an errors sheet to correct and upload again.
- `example/`: a Phoenix app with a `/bulk` page to copy, using no other library
  for its screens: organizations and roles a worker acts under, and files in a
  sheet.
- No Oban: the `bulk_actions` table is the queue. `AshBulkDurable.Core.Poller`,
  started by the host after its repo, claims bulk actions with `FOR UPDATE SKIP
  LOCKED` (a partial index keeps that cheap) and a lease the run renews
  (`lease_until`, `claim_token`, `attempts`, `shutdowns`). A dead node's bulk
  action is claimed again once its lease runs out and resumes from its rows;
  after `:max_attempts` claims it is failed `worker_lost`. A run that can't
  renew before its lease runs out stops by itself.
- Fencing: every worker write to the bulk action filters on its claim token.
  Every row write is a compare-and-set on the row's status and, inside its
  transaction just before it commits, confirms the run's claim token holds
  (`SELECT … FOR SHARE`), so a run that lost its claim writes nothing more.
- A run that raises, exits or throws is claimed again after a backoff
  (`:retry_backoff`) and on its last attempt is failed `raised` with what it
  raised, not `worker_lost`. A node shutting down releases its leases and
  refunds the attempt, at most `:max_attempts` times.
- Removed: the `oban` dependency, `oban_job_id`, `EnqueueWorker`,
  `Heartbeat`, `RescueStuckBulkActions`, and the `:oban`, `:queue`,
  `:worker_module` and `:worker_lost_after` config keys. New keys:
  `:poll_interval`, `:max_running`, `:lease_duration`, `:max_attempts`,
  `:retry_backoff`, `:staging_sweep_interval`, `:progress_interval`,
  `:warn_without_poller`.
- `rows_done` is no longer a column bumped inside each chunk's transaction,
  which held the bulk action's row locked for a whole all-or-nothing run: it
  and `rows_pending` are counts of the rows by status, loaded only when asked
  for. The worker broadcasts `"progress"` as chunks commit, at most once per
  `:progress_interval`, and an all-or-nothing run an uncommitted count as a
  hint (`AshBulkDurable.Core.Progress`).
- `PurgeStaleStaging` is a plain module: the poller runs `sweep/0` once a day
  on each node (it is idempotent). A failed bulk action keeps its files for a
  day from when it failed. Abandoning a bulk action deletes its staged files
  once the cancel commits, or leaves them to the sweep when it was made
  inside a caller's own transaction.
- Tests run bulk actions with `AshBulkDurable.Core.Worker.drain/0` and
  `run_now/1`, each in a watched process of its own.
- The engine's tests at the root, the screens' tests in `example/`, and CI over
  both.

### Upgrading from the Oban version

1. Stop every node running the old version, so no Oban job for a bulk action
   is still executing.
2. Delete the Oban jobs this library queued, which nothing runs any more
   (`AshBulkDurable.Core.Worker` has no `perform/1`):
   `DELETE FROM oban_jobs WHERE worker LIKE 'AshBulkDurable.%'`.
3. Remove `PurgeStaleStaging` and `RescueStuckBulkActions` from your Oban
   crontab. This is required, not tidying: the modules are gone, so
   `Oban.Config.new/1` raises on them and Oban won't start. If nothing else
   uses Oban, drop its tables with Oban's own down migration and remove the
   dependency.
4. Generate and run the migration for the new columns
   (`mix ash_postgres.generate_migrations`, then `mix ecto.migrate`). The
   generator asks whether you are renaming `oban_job_id` and `rows_done`:
   answer **n** to both. They are dropped; a yes would turn them into the
   new columns.
5. Add `AshBulkDurable.Core.Poller` to your supervision tree, after the repo
   and after `Ecto.Migrator` if you run migrations from there. Without it,
   bulk actions stay `:queued` with no error; a node with none warns once
   when one is queued (`warn_without_poller: false` silences that where it
   is meant, as in tests).
6. Set `:max_running` if your Oban queue for bulk actions allowed more than
   two at once: it replaces that limit, per node, and defaults to 2.
7. Load `:rows_done` and `:rows_pending` where you show them.

If you copied the example app's `/bulk` page, also:

- Remove its `rescue_if_stuck/1` call; the function is gone, which only
  shows as a compile warning.
- Handle the `"progress"` event (`AshBulkDurable.Core.Progress`) by reading
  the bulk action again. A catch-all `handle_info` drops it, and the bar
  stands still until the run finishes.
- Load the counts again when a notification arrives: its data comes without
  them.
- Load `:rows_done` before the retry flash subtracts it, or it raises.

A bulk action left `:running` by the old version has no lease: the first
poll claims it and resumes it from its rows.
