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

CSV and XLSX need no system packages. An XLSX is read by
[calamine](https://github.com/tafia/calamine), a Rust library, through
`spreadsheet`'s precompiled NIF, downloaded at compile time for the common
Linux, macOS and Windows targets.

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
| `:max_setup_failures` | `3` | starts that raise before reaching a row, or find its resource, action or stored terms missing on their node (as during a rolling deploy), with no progress between, before a bulk action fails; one missing them fails with `reason: :gone` or `:unreadable` |
| `:warn_without_poller` | `true` | warn when a bulk action is queued on a node with no poller |
| `:default_chunk_size` | `50` | rows a per-row bulk action commits per batch |
| `:halving_min_rows` | `8` | a failed chunk's rows are halved down to sets this small, then run row by row; `0` runs every row alone |
| `:atomic_mode_max_rows` | `10_000` | the cap on an all-or-nothing bulk action |
| `:phase1_concurrency` | `4` | rows resolved at once |
| `:field_handlers` | `[]` | handlers tried before the built-in ones |
| `:disable_defaults` | `[]` | built-in handlers to drop |
| `:excel_reader` | `AshBulkDurable.Sheet.ExcelReader.Calamine` | the `AshBulkDurable.Sheet.ExcelReader` that reads an XLSX |
| `:pubsub_module` | none | broadcasts each update, and progress hints, on `"bulk_action:<id>"` |
| `:progress_interval` | 1000 ms | the least time between two progress hints of one kind from a run; `0` sends every one |

## Progress hints

A page following a bulk action sees its committed updates on
`"bulk_action:<id>"`, as `Ash.Notifier.PubSub` notifications. Two stretches of
a run update nothing there: phase 1, which commits rows as their references
resolve but not the bulk action, and an all-or-nothing write, one transaction
that commits only at its end. For those the worker also broadcasts event
`"progress"` on the same topic, through `:pubsub_module` (as
`pubsub_module.broadcast(topic, "progress", payload)`):

```elixir
# phase 1, both modes; each row counted is committed, resolved or failed
%{bulk_action_id: id, pass: pass, phase: :resolving, committed: true,
  rows_resolved: n, rows_to_resolve: m}

# an all-or-nothing write; nothing is saved until the transaction commits
%{bulk_action_id: id, pass: pass, phase: :writing, committed: false,
  rows_processed: n, total_rows: m}
```

Each kind is sent at most once per `:progress_interval`, the first always,
and phase 1's last always. Ignore a hint whose `pass` differs from the bulk
action's (an older run's), and drop it once the bulk action's `status`,
`pass` or `rows_done` changes; not on every update, since a run's liveness
stamps update the bulk action too. Hints are best effort. A broadcast may be
sent inside a locked transaction, so `:pubsub_module`'s `broadcast/3` must not
block: the default local pubsub adapter doesn't, but one that publishes over
the network (Redis, say) would hold the lock while it does.
`AshBulkDurable.Core.Progress` has the details, and the example's `/bulk` page
shows them.

## Telemetry

`[:ash_bulk_durable, :bulk_action | :staged_files_download | :phase1 | :chunk]`
spans, and `[:ash_bulk_durable, :worker_attempt, :start]`,
`[:ash_bulk_durable, :isolation, :start]`, `[:ash_bulk_durable, :row, :crashed]`,
and the progress hints above as `[:ash_bulk_durable, :phase1, :progress]` and
`[:ash_bulk_durable, :all_or_nothing, :progress]` (the counts as measurements,
`bulk_action_id` and `pass` as metadata).

## Contributing

`mix test` needs PostgreSQL 16+. It connects to `db` as `admin`/`admin` unless
`DATABASE_HOST`, `DATABASE_USER` and `DATABASE_PASSWORD` say otherwise, and
sets up its own database from `priv/test_repo`. The engine's tests run here, on
the resources in `test/support`, and need no Phoenix. The screens' tests run in
`example/`.

## License

MIT
