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

  ## Defining your own actions

  The extension adds an action only where the host defines none of that
  name. A host that defines its own `:enqueue_retry` must accept a `pass`
  argument (an integer, which may be nil) and, when it is given, set the
  bulk action's `pass` to it: `AshBulkDurable.Core.Retry` always passes the
  pass it also writes onto the rows it reopens, and a retry through an
  action without the argument fails. A retry given `:staged_files` passes
  them as a `staged_files` argument (a map), which the action must set as
  the bulk action's `staged_files` (`AshBulkDurable.Core.Changes.ReopenBulkAction`
  does both).
  """
  use Spark.Dsl.Extension,
    transformers: [AshBulkDurable.Core.Resource.BulkAction.Transformer]
end
