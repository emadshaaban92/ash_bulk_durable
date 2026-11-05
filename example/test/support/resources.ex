defmodule Example.Test.Region do
  @moduledoc """
  Reference data only a platform admin writes: three unique columns, and two
  belongs_to a sheet can name, one a user who added it.
  """
  use Ash.Resource,
    domain: Example.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "regions"
    repo Example.Repo

    references do
      reference :inserted_by, on_delete: :restrict
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :native_name, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :inserted_by, Example.Accounts.User, public?: true, attribute_public?: true
    has_many :branches, Example.Test.Branch
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
      authorize_if {Example.Accounts.Checks.ActorHasPlatformRole, role: :platform_admin}
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end
end

defmodule Example.Test.Branch do
  @moduledoc "A record with one unique name that may name the region it is in."
  use Ash.Resource,
    domain: Example.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "branches"
    repo Example.Repo

    references do
      reference :region, on_delete: :restrict
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true, constraints: [trim?: true]
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
  end

  relationships do
    belongs_to :region, Example.Test.Region, public?: true
  end

  identities do
    identity :name, [:name]
  end

  actions do
    default_accept [:name, :region_id]
    defaults [:create, :read, :destroy]

    update :update do
      primary? true
      change increment(:version)
    end

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
      authorize_if {Example.Accounts.Checks.ActorHasPlatformRole, role: :platform_admin}
    end
  end
end

defmodule Example.Test.Asset do
  @moduledoc "A record two columns name together, a composite lookup."
  use Ash.Resource, domain: Example.Test.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "assets"
    repo Example.Repo
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

defmodule Example.Test.Booking do
  @moduledoc """
  A record whose only identities are partial, which name no one record, so a
  row can find it by its primary key alone. An organization reads its own,
  and only its officers release one.
  """
  use Ash.Resource,
    domain: Example.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Example.Accounts.Checks.{ActorHasOrganizationRole, ActorHasPlatformRole, ActorIsSuperUser}

  postgres do
    table "bookings"
    repo Example.Repo

    identity_wheres_to_sql order: "status != 'cancelled'", active_on_asset: "status = 'active'"
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :order_id, :uuid, public?: true
    attribute :organization_id, :uuid, public?: true
    attribute :refreshed, :boolean, allow_nil?: false, default: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      public?: true,
      constraints: [one_of: [:active, :cancelled]]
  end

  relationships do
    belongs_to :asset, Example.Test.Asset, public?: true
  end

  identities do
    identity :order, [:order_id], where: expr(status != :cancelled)
    identity :active_on_asset, [:asset_id], where: expr(status == :active)
  end

  actions do
    defaults [:read, create: [:asset_id, :organization_id]]

    create :import do
      accept [:asset_id]
    end

    update :refresh do
      accept []
      require_atomic? false
      change set_attribute(:refreshed, true)
      change Example.Test.Booking.ReadFromUpstream
    end

    update :release do
      accept []
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if ActorIsSuperUser
      authorize_if expr(organization_id == ^actor(:organization_id))
    end

    policy action_type(:create) do
      authorize_if {ActorHasPlatformRole, role: :platform_admin}
    end

    policy action(:refresh) do
      authorize_if ActorIsSuperUser
      authorize_if {ActorHasOrganizationRole, role: :officer}
    end

    policy action(:release) do
      authorize_if {ActorHasOrganizationRole, role: :officer}
    end
  end
end

defmodule Example.Test.Booking.ReadFromUpstream do
  @moduledoc """
  A refresh reads a system this app doesn't own, which can be down for one
  organization's bookings: it raises, in the words of whatever broke.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.data.organization_id in Application.get_env(:example, :upstream_down, []) do
        raise "SELECT a.reference FROM upstream.orders: relation does not exist"
      end

      changeset
    end)
  end
end

defmodule Example.Test.OrganizationScoped do
  @moduledoc """
  A resource scoped to an organization: `organization_id` attribute
  multitenancy, `global?` so a platform actor can act across organizations, and
  a `:code` unique per organization. Only its shape is asked about.
  """
  use Ash.Resource, domain: Example.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  relationships do
    belongs_to :organization, Example.Accounts.Organization do
      public? true
      allow_nil? false
    end
  end

  identities do
    identity :code, [:code], pre_check_with: Example.Test.Domain
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :name, :organization_id]
    end

    update :update do
      primary? true
      accept [:name]
    end
  end
end

defmodule Example.Test.RegionPin do
  @moduledoc "A record one required belongs_to identifies: a key that is a relationship."
  use Ash.Resource, domain: Example.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :note, :string, public?: true
  end

  relationships do
    belongs_to :region, Example.Test.Region do
      public? true
      allow_nil? false
    end
  end

  identities do
    identity :region, [:region_id], pre_check_with: Example.Test.Domain
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:region_id]
    end

    update :update do
      primary? true
      accept [:note]
    end
  end
end

defmodule Example.Test.Product do
  @moduledoc """
  A product with photos, the files a catalogue's bulk create and update carry
  in a companion ZIP. On ETS, which every process shares: the page, the test
  and the worker. ETS has no rollback, so a sheet that mixes a row that writes
  with one that fails meets its own insert when the chunk runs row by row:
  fail every row of a sheet, or none.
  """
  use Ash.Resource, domain: Example.Test.Domain, data_layer: Ash.DataLayer.Ets

  resource do
    plural_name :products
  end

  attributes do
    uuid_primary_key :id
    attribute :sku, :string, allow_nil?: false, public?: true
    attribute :stock, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :photos, {:array, Example.Types.StoredFile}, public?: true, default: []
  end

  identities do
    identity :sku, [:sku], pre_check_with: Example.Test.Domain
  end

  actions do
    defaults [:read, create: [:sku, :stock, :photos], update: [:stock, :photos]]
  end
end
