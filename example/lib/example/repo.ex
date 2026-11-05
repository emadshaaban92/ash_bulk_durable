defmodule Example.Repo do
  use AshPostgres.Repo, otp_app: :example, warn_on_missing_ash_functions?: true

  def installed_extensions, do: ["ash-functions", "citext"]

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
