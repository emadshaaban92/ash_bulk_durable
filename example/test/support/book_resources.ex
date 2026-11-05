defmodule Example.Test.Shelf do
  @moduledoc """
  What a book's sheet looks up: a record only its owner reads, with a
  composite identity whose second key can be null and an identity named
  unlike its key. Test-only, on ETS, which every process shares: the page,
  the test and the worker.
  """
  use Ash.Resource,
    domain: Example.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :aisle, :string, public?: true
    attribute :bay, :string, public?: true
    attribute :serial, :string, public?: true
    attribute :open, :boolean, allow_nil?: false, default: true, public?: true
    attribute :owner_id, :uuid, public?: true
  end

  identities do
    identity :code, [:code], pre_check_with: Example.Test.Domain
    identity :place, [:aisle, :bay], pre_check_with: Example.Test.Domain
    identity :shelf_mark, [:serial], pre_check_with: Example.Test.Domain
  end

  actions do
    defaults [:read, create: [:code, :aisle, :bay, :serial, :open, :owner_id]]
  end

  policies do
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(is_nil(owner_id))
      authorize_if expr(owner_id == ^actor(:id))
    end
  end
end

defmodule Example.Test.Vault do
  @moduledoc """
  A record a read refuses outright instead of filtering out, so a lookup
  meets a refusal rather than a miss. Test-only, like
  `Example.Test.Shelf`.
  """
  use Ash.Resource,
    domain: Example.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :code, [:code], pre_check_with: Example.Test.Domain
  end

  actions do
    defaults [:read, create: [:code]]
  end

  policies do
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      access_type :strict
      authorize_if Example.Accounts.Checks.ActorIsSuperUser
    end
  end
end

defmodule Example.Test.Volume do
  @moduledoc """
  A resource `/bulk` writes through a filtered relationship and a refused
  one, with an action that needs one bulk mode. Shapes the engine serves.
  ETS has no rollback, as
  `Example.Test.Product` says, so only a row failing at its lookup may
  sit beside one that writes.
  """
  use Ash.Resource, domain: Example.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :shelf, Example.Test.Shelf do
      public? true
      attribute_writable? true
      filter expr(open == true)
    end

    belongs_to :vault, Example.Test.Vault do
      public? true
      attribute_writable? true
    end
  end

  identities do
    identity :title, [:title], pre_check_with: Example.Test.Domain
  end

  actions do
    defaults [:read, create: [:title, :shelf_id, :vault_id]]

    create :catalogue do
      accept [:title]

      validate fn changeset, _context ->
        case changeset.context[:ash_bulk_durable][:mode] do
          :all_or_nothing ->
            :ok

          _mode ->
            {:error, field: :title, message: "a catalogue goes in whole or not at all"}
        end
      end
    end
  end
end
