defmodule Example.Types.StoredFile do
  @moduledoc """
  The key of a file in storage. Its own type so `Example.BulkActions.FileHandler`
  can claim the field: a sheet's cell names a file in the companion ZIP.
  """
  use Ash.Type.NewType, subtype_of: :string
end
