defmodule AshBulkDurable.Test.Domain do
  @moduledoc """
  What the tests run bulk actions over. The Postgres resources are listed so
  their tables have migrations; the rest are in-memory shapes, or have tables
  a test creates inside its own transaction.
  """
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true

    resource AshBulkDurable.Test.Organization
    resource AshBulkDurable.Test.User
    resource AshBulkDurable.Test.Membership
    resource AshBulkDurable.Test.Region
    resource AshBulkDurable.Test.Branch
    resource AshBulkDurable.Test.Asset
    resource AshBulkDurable.Test.Booking
  end
end
