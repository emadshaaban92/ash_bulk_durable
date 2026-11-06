defmodule AshBulkDurable.Test.Repo do
  @moduledoc "The database the library's tests run in. Its migrations are `priv/test_repo`."
  use AshPostgres.Repo, otp_app: :ash_bulk_durable, warn_on_missing_ash_functions?: true

  def installed_extensions, do: ["ash-functions", "citext"]

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule AshBulkDurable.Test.ReadRepo do
  @moduledoc """
  A second repo on the same database, standing in for a read replica: the
  bulk action and row resources send their `:read` queries here while a test
  points `:test_read_repo` at it. Its connections see neither another
  connection's lock nor its uncommitted writes, as a replica wouldn't.
  """
  use AshPostgres.Repo, otp_app: :ash_bulk_durable

  def installed_extensions, do: ["ash-functions", "citext"]

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @doc "The repo a resource's queries of `type` go to: reads to the stand-in replica while a test asks."
  def for_type(:read),
    do: Application.get_env(:ash_bulk_durable, :test_read_repo, AshBulkDurable.Test.Repo)

  def for_type(_mutate), do: AshBulkDurable.Test.Repo
end
