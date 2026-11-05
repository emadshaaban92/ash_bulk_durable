defmodule AshBulkDurable.Test.Repo do
  @moduledoc "The database the library's tests run in. Its migrations are `priv/test_repo`."
  use AshPostgres.Repo, otp_app: :ash_bulk_durable, warn_on_missing_ash_functions?: true

  def installed_extensions, do: ["ash-functions", "citext"]

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
