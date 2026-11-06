# ash_bulk_durable usage rules

- Call `AshBulkDurable`, the facade. `AshBulkDurable.Core` and
  `AshBulkDurable.Sheet` are the layers behind it.
- Every verb needs `:scope`. The bulk action is that user's, and the worker
  acts as them through the `AshBulkDurable.Core.Owner` you configure.
- A verb returning `{:ok, bulk_action}` means queued, not done. Read the bulk
  action's status, or subscribe with `:pubsub_module`.
- Bulk actions run only where `AshBulkDurable.Core.Poller` is in the
  supervision tree, after the repo. In tests, set `warn_without_poller: false`
  and run them with `AshBulkDurable.Core.Worker.run_now/1` or `drain/0`.
- `:per_row` commits rows in chunks and keeps failures to correct.
  `:all_or_nothing` is one transaction, capped by `:atomic_mode_max_rows`.
- Bulk actions reach your policies with the context
  `action_source: AshBulkDurable.action_source()`. A filter check denies under
  a record-less `Ash.can?`, so allow that source and hold the rule in a
  validation.
- Register custom cell handling as an `AshBulkDurable.Sheet.FieldHandler` under
  `:field_handlers`. Don't parse sheets yourself.
