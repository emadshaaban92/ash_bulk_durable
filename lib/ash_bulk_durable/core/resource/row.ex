defmodule AshBulkDurable.Core.Resource.Row do
  @moduledoc """
  `Spark.Dsl.Extension` that contributes the schema, actions, and postgres
  references for the host's `Row` shell resource: one per target + input
  the bulk action runs, FK back to `BulkAction` with `ON DELETE CASCADE`.

  Host usage:

      defmodule MyApp.BulkActions.Row do
        use Ash.Resource,
          domain: MyApp.BulkActions,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshBulkDurable.Core.Resource.Row]

        postgres do
          table "bulk_action_rows"
          repo MyApp.Repo
        end
      end

  The `:bulk_action` relationship is resolved through the
  `:bulk_action_resource` config key, so the extension does not need to
  know the host module ahead of time.

  ## Defining your own status flips

  The extension adds an action only where the host defines none of that name.
  Each row status flip is a compare-and-set: it matches the row only while
  its status is one it may move it from, so one run can't overwrite a row
  another run of the same bulk action already wrote. A host that defines its
  own `:resolve`, `:mark_succeeded`, `:mark_failed` or `:forget_resolutions`
  must keep that, by adding the guard as the action's first change:

      change {AshBulkDurable.Core.Changes.RequireStatus, statuses: [:resolved]}

  | Row action            | `statuses`              |
  |-----------------------|-------------------------|
  | `:resolve`            | `[:pending]`            |
  | `:mark_succeeded`     | `[:resolved]`           |
  | `:mark_failed`        | `[:pending, :resolved]` |
  | `:forget_resolutions` | `[:pending, :resolved]` |

  The same guard checks the run's pass. The worker's phase-1 writes
  (`:resolve`, and `:mark_failed` there) take no lock, so each gives its
  run's pass in the action context (`ash_bulk_durable: %{pass: pass}`), and
  `RequireStatus` then also matches the row only while the row's own `pass`
  is that one. `AshBulkDurable.Core.Retry` writes the next pass onto every
  row it reopens, so a run that started before a retry can't resolve or fail
  a row the retry reopened. A host's own action gets this from the guard and
  needs nothing more; the check reads the row's `pass` column, which the
  extension defines. A host's own `:reopen_with_corrections` must accept a
  `pass` argument and set the row's `pass` from it, and a host's own
  `:enqueue_retry` the same on the bulk action (see
  `AshBulkDurable.Core.Resource.BulkAction`): `AshBulkDurable.Core.Retry`
  always passes it, and a retry through an action without it fails. A write given no pass, such as a host's own call
  of the action, is matched on its status alone.
  """
  use Spark.Dsl.Extension,
    transformers: [AshBulkDurable.Core.Resource.Row.Transformer]
end
