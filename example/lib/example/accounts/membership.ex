defmodule Example.Accounts.Membership do
  @moduledoc "The roles a user holds at an organization."
  use Ash.Resource, domain: Example.Accounts, data_layer: AshPostgres.DataLayer

  postgres do
    table "memberships"
    repo Example.Repo
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :roles, {:array, :atom}, allow_nil?: false, default: [], public?: true
  end

  relationships do
    belongs_to :user, Example.Accounts.User, allow_nil?: false, public?: true
    belongs_to :organization, Example.Accounts.Organization, allow_nil?: false, public?: true
  end

  identities do
    identity :user_organization, [:user_id, :organization_id]
  end

  actions do
    defaults [:read, :destroy, create: [:user_id, :organization_id, :roles]]
  end
end
