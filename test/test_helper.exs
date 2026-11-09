# Passing tests run many refusals on purpose; their logs print only with a failure.
# The stress test runs only when asked for: `mix test --only stress`, and the
# tests against a real S3 API too: `mix test --only s3` (see
# test/storage/s3_api_test.exs).
ExUnit.start(capture_log: true, exclude: [:stress, :s3])

alias AshBulkDurable.Test.{PubSub, ReadRepo, Repo, S3Stub}

:ok = S3Stub.start()

{:ok, _pid} = Repo.start_link()
{:ok, _pid} = ReadRepo.start_link()
{:ok, _pid} = Supervisor.start_link([PubSub], strategy: :one_for_one)

Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

try do
  # A cold type cache reloads a type the first time a query names it, and a
  # second connection reading it mid-reload fails. Naming every column type and
  # its array here, on one connection before any test runs, closes that race.
  %{rows: [[types]]} =
    Repo.query!("""
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

  if types, do: Repo.query!("SELECT " <> Enum.map_join(types, ", ", &"NULL::#{&1}"))
after
  Ecto.Adapters.SQL.Sandbox.checkin(Repo)
end

Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(ReadRepo, :manual)
