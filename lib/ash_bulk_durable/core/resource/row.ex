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
  """
  use Spark.Dsl.Extension,
    transformers: [AshBulkDurable.Core.Resource.Row.Transformer]
end
