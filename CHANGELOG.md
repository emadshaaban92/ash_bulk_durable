# Changelog

## Unreleased

- First version: durable bulk actions on Oban, kept as `BulkAction` and `Row`
  records, with per-row and all-or-nothing modes, retries, a sheet layer for
  CSV and XLSX, and an errors sheet to correct and upload again.
- `example/`: a Phoenix app with a `/bulk` page to copy, using no other library
  for its screens: organizations and roles a worker acts under, and files in a
  sheet.
- `:oban` config key naming the Oban instance the engine uses for every job
  call, so a host with a named or prefixed instance works. The rescue cron's
  job lookup and the heartbeat now honour the instance's `:prefix`; before,
  on a prefixed host the cron failed every live bulk action.
- The engine's tests at the root, the screens' tests in `example/`, and CI over
  both.
- Row status flips are compare-and-set: `:resolve`, `:mark_succeeded`,
  `:mark_failed` and `:forget_resolutions` match a row only while its status
  is one they may move it from, and are refused as `StaleRecord` otherwise. A
  run whose row moved on under another run of the same bulk action stops
  without writing anything more: a superseded job cancels, the current one
  retries.
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
  runs of one bulk action take turns rather than both writing it. The worker
  no longer marks the bulk action `:running` before phase 1: the first locked
  transaction does, so it stays `:queued` while its references resolve, and
  `started_at` is when its first chunk started, leaving phase 1 out of the
  run's duration. Every target must live in the bulk action's repo.
