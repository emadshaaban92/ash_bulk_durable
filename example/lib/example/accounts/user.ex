defmodule Example.Accounts.User do
  @moduledoc """
  A person, read within their organization. A super user acts anywhere; the
  rest hold roles at the organizations they belong to.
  """
  use Ash.Resource,
    domain: Example.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Example.Accounts.Checks.{ActorHasOrganizationRole, ActorHasPlatformRole}
  alias Example.Accounts.Checks.{ActorIsSuperUser, ChangingPlatformRoles}
  alias Example.Accounts.MemberOfOrganization

  postgres do
    table "users"
    repo Example.Repo
  end

  # Global, so a super user can act with no organization chosen.
  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :phone, :string, public?: true

    attribute :platform_roles, {:array, :atom}, allow_nil?: false, default: [], public?: true
    # What an actor's policies read, for the organization they act in now.
    # `Example.BulkActions.Owner` fills it for the one a worker acts in.
    attribute :organization_roles, {:array, :atom}, allow_nil?: false, default: [], public?: true
    timestamps()
  end

  relationships do
    belongs_to :organization, Example.Accounts.Organization, public?: true
    has_many :memberships, Example.Accounts.Membership
  end

  identities do
    identity :email, [:email], all_tenants?: true
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
      validate MemberOfOrganization
    end

    update :update_profile do
      accept [:name, :phone]
    end

    update :promote_to_super do
      accept []
      change set_attribute(:platform_roles, [:super_user])
    end

    update :change_tenant do
      accept []
      require_atomic? false
      argument :organization_id, :uuid, allow_nil?: false
      change set_attribute(:organization_id, arg(:organization_id))

      # Acting there with the roles held there, none for a super user.
      change fn changeset, _context ->
        roles =
          MemberOfOrganization.membership_roles(
            changeset.data.id,
            Ash.Changeset.get_argument(changeset, :organization_id)
          )

        Ash.Changeset.force_change_attribute(changeset, :organization_roles, roles || [])
      end

      validate MemberOfOrganization
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

    policy action([:create, :update]) do
      authorize_if {ActorHasOrganizationRole, role: :admin}
      authorize_if {ActorHasPlatformRole, role: :platform_admin}
    end

    # Platform roles reach past every organization, so an organization or
    # platform admin who could hand them out could make anyone, themselves
    # included, a super user. Only a super user changes them, by hand, as
    # with :promote_to_super.
    policy [action([:create, :update]), ChangingPlatformRoles] do
      forbid_if context_equals(:action_source, :ash_bulk_durable)
      authorize_if ActorIsSuperUser
    end

    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    # One person vouching for one person, however many a sheet could name.
    policy action(:promote_to_super) do
      forbid_if context_equals(:action_source, :ash_bulk_durable)
      authorize_if ActorIsSuperUser
    end

    policy action(:update) do
      authorize_if expr(id == ^actor(:id))
      forbid_if expr(:super_user in platform_roles)
      authorize_if {ActorHasOrganizationRole, role: :admin}
      authorize_if {ActorHasPlatformRole, role: :platform_admin}
      authorize_if expr(organization_id == ^actor(:organization_id))
    end
  end
end
