# Passing tests run many refusals on purpose; their logs print only with a failure.
ExUnit.start(capture_log: true)

Ecto.Adapters.SQL.Sandbox.checkout(Example.Repo, sandbox: false)

try do
  # A cold type cache reloads a type the first time a query names it, and a
  # second connection reading it mid-reload fails. Naming every column type and
  # its array here, on one connection before any test runs, closes that race.
  %{rows: [[types]]} =
    Example.Repo.query!("""
    SELECT array_agg(DISTINCT oid::regtype::text)
    FROM (
      SELECT unnest(ARRAY[a.atttypid, t.typarray]) AS oid
      FROM pg_attribute AS a
      JOIN pg_class AS c ON c.oid = a.attrelid
      JOIN pg_type AS t ON t.oid = a.atttypid
      WHERE c.relkind = 'r'
        AND c.relnamespace = 'public'::regnamespace
        AND a.attnum > 0
        AND NOT a.attisdropped
    ) AS used
    WHERE oid <> 0
    """)

  if types, do: Example.Repo.query!("SELECT " <> Enum.map_join(types, ", ", &"NULL::#{&1}"))
after
  Ecto.Adapters.SQL.Sandbox.checkin(Example.Repo)
end

Ecto.Adapters.SQL.Sandbox.mode(Example.Repo, :manual)
