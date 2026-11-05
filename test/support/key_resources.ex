defmodule AshBulkDurable.Test.Plate do
  @moduledoc """
  A resource keyed by one attribute not named `id`, a shape the bulk engine
  serves. Test-only, on ETS.
  """
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :number, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:number, :name], update: [:name]]
  end
end

defmodule AshBulkDurable.Test.Seat do
  @moduledoc """
  A resource keyed by two attributes, a shape the bulk engine serves.
  Test-only, on ETS.
  """
  use Ash.Resource, domain: AshBulkDurable.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :hall, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :number, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:hall, :number, :name], update: [:name]]
  end
end
