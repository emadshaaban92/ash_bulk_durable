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
  """
  use Spark.Dsl.Extension,
    transformers: [AshBulkDurable.Core.Resource.Row.Transformer]
end
