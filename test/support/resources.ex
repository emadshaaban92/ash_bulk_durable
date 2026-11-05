defmodule AshBulkDurable.Test.Region do
  @moduledoc """
  Reference data only a platform admin writes: three unique columns, and two
  belongs_to a sheet can name, one a user who added it.
  """
  use Ash.Resource,
    domain: AshBulkDurable.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "regions"
    repo AshBulkDurable.Test.Repo

    references do
      reference :inserted_by, on_delete: :restrict
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :native_name, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :inserted_by, AshBulkDurable.Test.User, public?: true, attribute_public?: true
    has_many :branches, AshBulkDurable.Test.Branch
  end

  identities do
    identity :code, [:code]
    identity :name, [:name]
    identity :native_name, [:native_name]
  end

  actions do
    default_accept [:name, :code, :native_name]
    defaults [:create, :read, :update, :destroy]

    read :by_code do
      argument :code, :string, allow_nil?: false
      get? true
      filter expr(code == ^arg(:code))
    end
  end

  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if {AshBulkDurable.Test.Checks.ActorHasPlatformRole, role: :platform_admin}
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end
end

defmodule AshBulkDurable.Test.Branch do
  @moduledoc "A record with one unique name that may name the region it is in."
  use Ash.Resource,
    domain: AshBulkDurable.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "branches"
    repo AshBulkDurable.Test.Repo

    references do
      reference :region, on_delete: :restrict
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true, constraints: [trim?: true]
  end

  relationships do
    belongs_to :region, AshBulkDurable.Test.Region, public?: true
  end

  identities do
    identity :name, [:name]
  end

  actions do
    default_accept [:name, :region_id]
    defaults [:create, :read, :update, :destroy]

    read :index do
      prepare build(sort: [name: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_present()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {AshBulkDurable.Test.Checks.ActorHasPlatformRole, role: :platform_admin}
    end
  end
end

defmodule AshBulkDurable.Test.Asset do
  @moduledoc "A record two columns name together, a composite lookup."
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "assets"
    repo AshBulkDurable.Test.Repo
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :serial_number, :string, allow_nil?: false, public?: true
    attribute :batch_number, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :serial_and_batch, [:serial_number, :batch_number]
  end

  actions do
    defaults [:read, create: [:serial_number, :batch_number]]
  end
end

defmodule AshBulkDurable.Test.Booking do
  @moduledoc """
  A record whose only identities are partial, which name no one record, so a
  row can find it by its primary key alone; with an action whose documents
  come in a companion ZIP.
  """
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "bookings"
    repo AshBulkDurable.Test.Repo

    identity_wheres_to_sql order: "status != 'cancelled'", active_on_asset: "status = 'active'"
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :order_id, :uuid, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      public?: true,
      constraints: [one_of: [:active, :cancelled]]
  end

  relationships do
    belongs_to :asset, AshBulkDurable.Test.Asset, public?: true
  end

  identities do
    identity :order, [:order_id], where: expr(status != :cancelled)
    identity :active_on_asset, [:asset_id], where: expr(status == :active)
  end

  actions do
    defaults [:read]

    create :import do
      accept [:asset_id]
    end

    update :refresh do
      accept []
    end

    update :change_holder do
      accept []
      require_atomic? false
      argument :document, {:array, AshBulkDurable.Test.StoredFile}
    end
  end
end
