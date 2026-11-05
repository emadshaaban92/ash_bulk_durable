defmodule Example.Test.Domain do
  @moduledoc """
  Shapes `/bulk` meets that the example's own resources lack. The Postgres
  ones are listed so `priv/test_repo` holds their tables; the rest are
  in-memory, or have tables a test creates inside its own transaction.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true

    resource Example.Test.Region
    resource Example.Test.Branch
    resource Example.Test.Asset
    resource Example.Test.Booking
  end
end
