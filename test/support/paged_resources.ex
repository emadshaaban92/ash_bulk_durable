defmodule AshBulkDurable.Test.PagedBin do
  @moduledoc """
  What a lookup reads through a primary read that pages by default, as an
  app serving it over an API often has. Looked up by `aisle`, which names no
  identity and no one record, by a reference or by an update's or a
  destroy's target, which its shelf may narrow. Test-only, on ETS.
  """
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :aisle, :string, public?: true
  end

  relationships do
    belongs_to :shelf, AshBulkDurable.Test.Shelf, public?: true
  end

  actions do
    defaults [:destroy, create: [:aisle, :shelf_id], update: [:aisle]]

    read :read do
      primary? true
      pagination keyset?: true, default_limit: 10, paginate_by_default?: true
    end
  end
end

defmodule AshBulkDurable.Test.LimitedBin do
  @moduledoc """
  What a lookup reads through a primary read that requires a page and sets
  no default limit. Looked up by `aisle`, as `AshBulkDurable.Test.PagedBin`
  is. Test-only, on ETS.
  """
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :aisle, :string, public?: true
  end

  actions do
    defaults [:destroy, create: [:aisle], update: [:aisle]]

    read :read do
      primary? true
      pagination offset?: true, required?: true
    end
  end
end
