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
