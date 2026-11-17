defmodule AshBulkDurable.Test.BulkActions do
  @moduledoc """
  The shells an app declares, set up as the README's: authorization is on,
  the engine's own reads and writes skip it, and anyone else's go through
  the resources' policies.
  """
  use Ash.Domain

  resources do
    resource AshBulkDurable.Test.BulkAction
    resource AshBulkDurable.Test.Row
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
    repo fn _resource, type -> AshBulkDurable.Test.ReadRepo.for_type(type) end

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
    repo fn _resource, type -> AshBulkDurable.Test.ReadRepo.for_type(type) end
  end

  policies do
    policy action_type(:read) do
      authorize_if AshBulkDurable.Test.Checks.ActorIsSuperUser
      authorize_if expr(bulk_action.user_id == ^actor(:id))
    end
  end
end

defmodule AshBulkDurable.Test.DestroyingBulkAction do
  @moduledoc """
  A bulk action whose host opts into a `:destroy`. It is in no domain, and
  only its actions are looked at.
  """
  use Ash.Resource,
    domain: nil,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBulkDurable.Core.Resource.BulkAction]

  postgres do
    table "bulk_actions"
    repo AshBulkDurable.Test.Repo
  end

  actions do
    defaults [:destroy]
  end
end
