# AshBulkDurable

Run any Ash action over many rows durably. A bulk action and its rows are
written in one transaction, then a poller on one of the app's nodes runs them.
Rows that fail stay behind with their errors, to correct and retry, and a bulk
action survives a restart or a lost node: another node resumes it.

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

The library stands on Ash and Postgres. It has no screens and needs no web
framework, and no job queue: the `bulk_actions` table is the only record of
what needs running.

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

Every resource a bulk action writes must live in the same repo as these two.
A chunk's target writes share the transaction that holds the bulk action's
lock; a target in another repo writes on another connection, outside it, and
silently loses the lock's protection.

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

Add the poller last to each node's supervision tree, after the repo, anything
that migrates it, and the PubSub and endpoint a run broadcasts through. It then
stops first, so the runs it lets finish on shutdown can still broadcast:

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Endpoint,
  AshBulkDurable.Core.Poller
]
```

It starts each queued bulk action as soon as it is submitted or retried on its
node, and every few seconds starts any other node's: one queued, or one whose
run died with its node. It also runs the daily sweep of staged files. Without
a poller, bulk actions stay queued and a warning is logged once; set
`warn_without_poller: false` on nodes that leave the work to others, and in
tests, which run bulk actions with `AshBulkDurable.Core.Worker.run_now/1` or
`drain/0`.

Its options, each also an `:ash_bulk_durable` config key:

| Option | Default | |
|---|---|---|
| `:poll_interval` | 5 seconds | how often it looks for bulk actions to start |
| `:max_running` | `2` | bulk actions this node runs at once |
| `:stale_after` | 2 minutes | how long a running bulk action's liveness hint may go unstamped before another run starts it |
| `:staging_sweep_interval` | a day | between staged-file sweeps; `nil` for none |
| `:shutdown_grace` | 20 seconds | how long a run still going at shutdown has to finish before it is killed |

A run stamps its bulk action's liveness hint (`alive_at`) as it goes, and at
least every `:alive_interval` (30 seconds by default). Two runs of one bulk
action are harmless, since each chunk runs under the bulk action's row lock,
so the hint only decides when to start one. Each running bulk action takes one
connection, up to `:phase1_concurrency` more while it resolves references, and
one more for its ticker's stamp, held briefly each `:alive_interval`: size the
repo's pool for `:max_running` times `:phase1_concurrency + 2`.

## Other config

| Key | Default | |
|---|---|---|
| `:alive_interval` | 30 seconds | how often a run stamps its liveness hint |
| `:max_stalled_starts` | `3` | starts in a row without progress before a bulk action's rows run alone |
| `:max_row_attempts` | `2` | runs that may die on a row run alone before it fails as crashed |
| `:warn_without_poller` | `true` | warn when a bulk action is queued on a node with no poller |
| `:default_chunk_size` | `50` | rows a per-row bulk action commits per batch |
| `:halving_min_rows` | `8` | a failed chunk's rows are halved down to sets this small, then run row by row; `0` runs every row alone |
| `:atomic_mode_max_rows` | `10_000` | the cap on an all-or-nothing bulk action |
| `:phase1_concurrency` | `4` | rows resolved at once |
| `:field_handlers` | `[]` | handlers tried before the built-in ones |
| `:disable_defaults` | `[]` | built-in handlers to drop |
| `:pubsub_module` | none | broadcasts each update on `"bulk_action:<id>"` |

## Telemetry

`[:ash_bulk_durable, :bulk_action | :staged_files_download | :phase1 | :chunk]`
spans, and `[:ash_bulk_durable, :worker_attempt, :start]`,
`[:ash_bulk_durable, :isolation, :start]` and `[:ash_bulk_durable, :row, :crashed]`.

## Contributing

`mix test` needs PostgreSQL 16+. It connects to `db` as `admin`/`admin` unless
`DATABASE_HOST`, `DATABASE_USER` and `DATABASE_PASSWORD` say otherwise, and
sets up its own database from `priv/test_repo`. The engine's tests run here, on
the resources in `test/support`, and need no Phoenix. The screens' tests run in
`example/`.

## License

MIT
