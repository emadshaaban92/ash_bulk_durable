# AshBulkDurable

Run any Ash action over many rows durably. A bulk action and its rows are
written in one transaction, then a poller on any node claims the bulk action
and runs it. Rows that fail stay behind with their errors, to correct and
retry, and a bulk action survives a restart or a lost node.

The verbs are Ash's, with its argument orders. Each takes a list of inputs or a
sheet, and returns `{:ok, bulk_action}` once the work is queued:

```elixir
AshBulkDurable.bulk_create([%{title: "Hello"}], Post, :create, scope: scope)

{:ok, sheet} = AshBulkDurable.read_sheet("posts.csv")

AshBulkDurable.update_many(sheet, Post, :update,
  identity: :slug,
  mapping: [columns: %{slug: "Slug", title: "Title"}],
  scope: scope
)

AshBulkDurable.bulk_destroy(ids, :destroy, resource: Post, scope: scope)
```

See `AshBulkDurable` for every verb and option.

The library stands on Ash and Postgres; the `bulk_actions` table is its queue.
It has no screens and needs no web framework.

[`example/`](example/README.md) is a Phoenix app using it, with a `/bulk` page
to copy into yours.

## Installation

```elixir
def deps do
  [
    {:ash_bulk_durable, github: "emadshaaban92/ash_bulk_durable"}
  ]
end
```

Reading an XLSX shells out to `in2csv`, from [csvkit](https://csvkit.readthedocs.io).
CSV needs nothing.

## Setup

Your app owns two resources, which the library's extensions fill in:

```elixir
defmodule MyApp.BulkActions.BulkAction do
  use Ash.Resource,
    domain: MyApp.BulkActions,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshBulkDurable.Core.Resource.BulkAction]

  postgres do
    table "bulk_actions"
    repo MyApp.Repo

    identity_wheres_to_sql one_unresolved_per_user:
                             "status IN ('queued', 'running', 'completed_with_errors')"
  end
end

defmodule MyApp.BulkActions.Row do
  use Ash.Resource,
    domain: MyApp.BulkActions,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBulkDurable.Core.Resource.Row]

  postgres do
    table "bulk_action_rows"
    repo MyApp.Repo
  end
end
```

Name them in config, with an owner and a storage adapter:

```elixir
config :ash_bulk_durable,
  bulk_action_resource: MyApp.BulkActions.BulkAction,
  row_resource: MyApp.BulkActions.Row,
  owner_module: MyApp.BulkActions.Owner,
  storage: MyApp.BulkActions.Storage
```

- `AshBulkDurable.Core.Owner` says who a bulk action belongs to, and how the
  worker acts as them again.
- `AshBulkDurable.Core.Storage` reads, lists and deletes staged files. The
  library ships no adapter.

Start the poller on every node that should run bulk actions, after your repo
and after anything that migrates it:

```elixir
children = [
  MyApp.Repo,
  {Ecto.Migrator, repos: [MyApp.Repo]},
  AshBulkDurable.Core.Poller,
  MyAppWeb.Endpoint
]
```

Without a poller, bulk actions stay `:queued` and nothing fails, and a test
suite won't notice, since tests run without it. So a node where a bulk action
is submitted or retried with no poller running logs a warning, once. Set
`warn_without_poller: false` on nodes that leave bulk actions to others, and
in test config. `Process.whereis(AshBulkDurable.Core.Poller)` tells whether a
node runs one.

It claims queued bulk actions (`FOR UPDATE SKIP LOCKED`, oldest first) and runs
up to `:max_running` at once, claiming again as soon as a run ends and when a
bulk action is submitted or retried on its node. A claim holds a bulk action for a lease the run
keeps renewing; a node that dies stops renewing, and once its lease runs out
any node claims the bulk action again and resumes it from its rows. A run that
can't renew before its lease runs out stops by itself. Every row write only goes
through if the row is still in the status its run read, and confirms the run's
claim just before it commits, so a run that lost its claim writes nothing more.

A run that raises, exits or throws is claimed again after a backoff
(`:retry_backoff` times the attempt squared), and on its last attempt is failed
`raised` with what it raised. After `:max_attempts` claims that died it is
failed `worker_lost`. Either way its owner can retry it. A node shutting down
gives its leases back without using up an attempt (up to `:max_attempts`
times), so deploys don't count against a run. The poller also sweeps stale
staged files once a day; a failed bulk action keeps its files for a day from
when it failed, to be retried.

In tests, leave the poller out and run bulk actions with
`AshBulkDurable.Core.Worker.drain/0` or `run_now/1`. They run each one in a
process of their own, watched, with the test's sandboxed connection, so a lost
lease doesn't take the test down. A run that raises waits out its backoff
`:running`, so `drain/0` stops there; set `retry_backoff: 0` in test config to
have it drain to the final `:failed`. A test that watches a page move chunk by
chunk sets `progress_interval: 0`, and `warn_without_poller: false` keeps
the poller warning out of the test log.

## Other config

| Key | Default | |
|---|---|---|
| `:poll_interval` | `5_000` | milliseconds between the poller's claims |
| `:max_running` | `2` | bulk actions a node runs at once |
| `:lease_duration` | `60_000` | milliseconds a claim holds a bulk action; the run renews it every third of that |
| `:max_attempts` | `3` | claims a bulk action gets before it is failed `worker_lost` |
| `:retry_backoff` | `15_000` | milliseconds a run that raised waits before its next claim, times the attempt squared |
| `:staging_sweep_interval` | one day | milliseconds between staged-file sweeps; `nil` runs none |
| `:default_chunk_size` | `50` | rows a per-row bulk action commits per batch |
| `:atomic_mode_max_rows` | `10_000` | the cap on an all-or-nothing bulk action |
| `:phase1_concurrency` | `4` | rows resolved at once |
| `:field_handlers` | `[]` | handlers tried before the built-in ones |
| `:disable_defaults` | `[]` | built-in handlers to drop |
| `:pubsub_module` | none | broadcasts each update, and the worker's progress, on `"bulk_action:<id>"` |
| `:progress_interval` | `1_000` | milliseconds between a run's `"progress"` broadcasts for one bulk action |
| `:warn_without_poller` | `true` | warn, once per node, when a bulk action is queued on a node with no poller |

A bulk action's `rows_done` and `rows_pending` count its rows by status. They
are aggregates, loaded only when asked for (`load: [:rows_done,
:rows_pending]`), so a page showing progress pays for the count and nothing
else does. The worker broadcasts `"progress"` as rows resolve and chunks
commit, at most once per `:progress_interval` (always at the start and at the
end of resolving references), so a page reads the bulk action again
(`AshBulkDurable.Core.Progress`).

## Telemetry

`[:ash_bulk_durable, :bulk_action | :staged_files_download | :phase1 | :chunk]`
spans, `[:ash_bulk_durable, :worker_attempt, :start]` (its `attempt` counts the
bulk action's claims), and `[:ash_bulk_durable, :all_or_nothing, :progress]`
with the rows an all-or-nothing transaction has processed, none saved yet.

## Contributing

`mix test` needs PostgreSQL 16+. It connects to `db` as `admin`/`admin` unless
`DATABASE_HOST`, `DATABASE_USER` and `DATABASE_PASSWORD` say otherwise, and
sets up its own database from `priv/test_repo`. The engine's tests run here, on
the resources in `test/support`, and need no Phoenix. The screens' tests run in
`example/`.

## License

MIT
