defmodule Example.BulkActions.Row do
  @moduledoc "One row of a bulk action. Reads follow its bulk action's owner."
  use Ash.Resource,
    domain: Example.BulkActions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshBulkDurable.Core.Resource.Row]

  postgres do
    table "bulk_action_rows"
    repo Example.Repo
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(bulk_action.user_id == ^actor(:id))
    end
  end
end
