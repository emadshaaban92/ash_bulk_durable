defmodule AshBulkDurable.Test.BulkActions do
  @moduledoc """
  The shells an app declares. The worker writes progress with no user behind
  it, so authorization is opt-in here.
  """
  use Ash.Domain

  resources do
    resource AshBulkDurable.Test.BulkAction
    resource AshBulkDurable.Test.Row
  end

  authorization do
    require_actor? false
    authorize :when_requested
  end
end

defmodule AshBulkDurable.Test.BulkAction do
  @moduledoc "A bulk action. Reads are its owner's and a super user's."
  use Ash.Resource,
    domain: AshBulkDurable.Test.BulkActions,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshBulkDurable.Core.Resource.BulkAction]

  postgres do
    table "bulk_actions"
    repo AshBulkDurable.Test.Repo

    identity_wheres_to_sql one_unresolved_per_user:
                             "status IN ('queued', 'running', 'completed_with_errors')"
  end

  policies do
    policy action_type(:read) do
      authorize_if AshBulkDurable.Test.Checks.ActorIsSuperUser
      authorize_if expr(user_id == ^actor(:id))
    end
  end
end

defmodule AshBulkDurable.Test.Row do
  @moduledoc "One row of a bulk action. Reads follow its bulk action's owner."
  use Ash.Resource,
    domain: AshBulkDurable.Test.BulkActions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshBulkDurable.Core.Resource.Row]

  postgres do
    table "bulk_action_rows"
    repo AshBulkDurable.Test.Repo
  end

  # Narrower than the bulk action's: an actor with the `:row_blind` platform
  # role reads its own bulk actions but none of their rows.
  policies do
    policy action_type(:read) do
      forbid_if expr(:row_blind in ^actor(:platform_roles))
      authorize_if AshBulkDurable.Test.Checks.ActorIsSuperUser
      authorize_if expr(bulk_action.user_id == ^actor(:id))
    end
  end
end
