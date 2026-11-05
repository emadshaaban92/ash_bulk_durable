defmodule Example.Library.Author do
  @moduledoc false
  use Ash.Resource, domain: Example.Library, data_layer: AshPostgres.DataLayer

  postgres do
    table "authors"
    repo Example.Repo
  end

  actions do
    defaults [:read, :destroy, create: [:name, :email], update: [:name, :email]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    has_many :books, Example.Library.Book, public?: true
  end

  identities do
    identity :email, [:email]
  end
end
