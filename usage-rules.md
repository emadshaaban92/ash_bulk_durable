# ash_bulk_durable usage rules

- Call `AshBulkDurable`, the facade. `AshBulkDurable.Core` and
  `AshBulkDurable.Sheet` are the layers behind it.
- Every verb needs `:scope`. The bulk action is that user's, and the worker
  acts as them through the `AshBulkDurable.Core.Owner` you configure.
- A verb returning `{:ok, bulk_action}` means queued, not done. Start
  `AshBulkDurable.Core.Poller` in your supervision tree after the repo and
  its migrator, or nothing runs (a node with none warns once when a bulk
  action is queued; `warn_without_poller: false` silences it). Read the bulk action's status, or subscribe with
  `:pubsub_module`.
- There is no Oban. The `bulk_actions` table is the queue; don't enqueue jobs
  for bulk actions. In tests, run them with `AshBulkDurable.Core.Worker.drain/0`
  or `run_now/1` instead of starting the poller.
- `rows_done` is counted from the rows, not stored, and loaded only when asked
  for: read the bulk action again with `load: [:rows_done, :rows_pending]`
  after a `"progress"` broadcast to see it move.
- `:per_row` commits rows in chunks and keeps failures to correct.
  `:all_or_nothing` is one transaction, capped by `:atomic_mode_max_rows`.
- Bulk actions reach your policies with the context
  `action_source: AshBulkDurable.action_source()`. A filter check denies under
  a record-less `Ash.can?`, so allow that source and hold the rule in a
  validation.
- Register custom cell handling as an `AshBulkDurable.Sheet.FieldHandler` under
  `:field_handlers`. Don't parse sheets yourself.
