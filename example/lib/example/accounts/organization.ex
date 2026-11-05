defmodule Example.Accounts.Organization do
  @moduledoc "The tenant a user acts for."
  use Ash.Resource, domain: Example.Accounts, data_layer: AshPostgres.DataLayer

  postgres do
    table "organizations"
    repo Example.Repo
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
    defaults [:read, create: [:code, :name], update: [:name]]
  end
end
