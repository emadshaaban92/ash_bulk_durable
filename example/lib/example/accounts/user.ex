defmodule Example.Accounts.User do
  @moduledoc false
  use Ash.Resource, domain: Example.Accounts, data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo Example.Repo
  end

  actions do
    defaults [:read, create: [:name, :email]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :string, allow_nil?: false, public?: true
    timestamps()
  end

  identities do
    identity :email, [:email]
  end
end
