defmodule AshBulkDurable.Test.Organization do
  @moduledoc false
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "organizations"
    repo AshBulkDurable.Test.Repo
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end

  identities do
    identity :code, [:code]
  end

  actions do
    defaults [:read, create: [:code, :name]]
  end
end

defmodule AshBulkDurable.Test.Membership do
  @moduledoc "The roles a user holds at an organization."
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "memberships"
    repo AshBulkDurable.Test.Repo
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :roles, {:array, :atom}, allow_nil?: false, default: [], public?: true
  end

  relationships do
    belongs_to :user, AshBulkDurable.Test.User, allow_nil?: false, public?: true
    belongs_to :organization, AshBulkDurable.Test.Organization, allow_nil?: false, public?: true
  end

  identities do
    identity :user_organization, [:user_id, :organization_id]
  end

  actions do
    defaults [:read, create: [:user_id, :organization_id, :roles]]
  end
end

defmodule AshBulkDurable.Test.User do
  @moduledoc """
  A person, read within their organization, with the shapes a sheet meets on
  an account: a case-insensitive email and an optional phone.
  """
  use Ash.Resource,
    domain: AshBulkDurable.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias AshBulkDurable.Test.Checks.{ActorHasOrganizationRole, ActorHasPlatformRole}
  alias AshBulkDurable.Test.Checks.ActorIsSuperUser

  postgres do
    table "users"
    repo AshBulkDurable.Test.Repo
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :phone, :string, public?: true
    attribute :platform_roles, {:array, :atom}, allow_nil?: false, default: [], public?: true
    # What an actor's policies read. `AshBulkDurable.Test.Owner` fills it for the
    # organization a worker acts in, and the test helpers for the one a user joined.
    attribute :organization_roles, {:array, :atom}, allow_nil?: false, default: [], public?: true
  end

  relationships do
    belongs_to :organization, AshBulkDurable.Test.Organization, public?: true
    has_many :memberships, AshBulkDurable.Test.Membership
  end

  identities do
    identity :email, [:email]
  end

  code_interface do
    define :change_tenant, args: [:organization_id]
  end

  actions do
    default_accept [:name, :email, :phone, :platform_roles]
    defaults [:read, :create]

    create :create_super do
      accept [:name, :email]
      change set_attribute(:platform_roles, [:super_user])
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :email, :phone, :platform_roles, :organization_id, :organization_roles]
    end

    update :change_tenant do
      accept []
      require_atomic? false
      argument :organization_id, :uuid, allow_nil?: false
      change set_attribute(:organization_id, arg(:organization_id))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if ActorIsSuperUser
      forbid_if expr(:super_user in platform_roles)
      authorize_if {ActorHasPlatformRole, role: :platform_admin}
      authorize_if expr(id == ^actor(:id))
      authorize_if expr(organization_id == ^actor(:organization_id))
    end

    policy action_type(:create) do
      authorize_if {ActorHasOrganizationRole, role: :admin}
      authorize_if {ActorHasPlatformRole, role: :platform_admin}
    end

    policy action_type(:update) do
      authorize_if expr(id == ^actor(:id))
      forbid_if expr(:super_user in platform_roles)
      authorize_if {ActorHasPlatformRole, role: :platform_admin}
      authorize_if expr(organization_id == ^actor(:organization_id))
    end
  end
end
