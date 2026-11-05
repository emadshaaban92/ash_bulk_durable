defmodule Example.Library.Book do
  @moduledoc false
  use Ash.Resource, domain: Example.Library, data_layer: AshPostgres.DataLayer

  postgres do
    table "books"
    repo Example.Repo

    references do
      reference :author, on_delete: :restrict
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:isbn, :title, :pages, :cover, :author_id],
      update: [:title, :pages, :cover, :author_id]
    ]
  end

  validations do
    validate numericality(:pages, greater_than: 0)
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :isbn, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :pages, :integer, public?: true
    attribute :cover, Example.Types.StoredFile, public?: true
    timestamps()
  end

  relationships do
    belongs_to :author, Example.Library.Author, allow_nil?: false, public?: true
  end

  identities do
    identity :isbn, [:isbn]
  end
end
