defmodule AshBulkDurable.Core.Resource.BulkAction do
  @moduledoc """
  `Spark.Dsl.Extension` that contributes the schema, actions, identities,
  notifier config, and postgres references to the host's `BulkAction` shell
  resource.

  Host usage:

      defmodule MyApp.BulkActions.BulkAction do
        use Ash.Resource,
          domain: MyApp.BulkActions,
          data_layer: AshPostgres.DataLayer,
          notifiers: [Ash.Notifier.PubSub],
          extensions: [AshBulkDurable.Core.Resource.BulkAction]

        postgres do
          table "bulk_actions"
          repo MyApp.Repo
        end
      end

  When `:pubsub_module` is set in the `:ash_bulk_durable` config block (e.g.
  `config :ash_bulk_durable, pubsub_module: MyAppWeb.Endpoint`), the
  extension fills in the `pub_sub` block automatically — every `:update`
  is broadcast on `"bulk_action:<id>"`.
  """
  use Spark.Dsl.Extension,
    transformers: [AshBulkDurable.Core.Resource.BulkAction.Transformer]
end
