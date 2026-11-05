# AshBulkDurable

Run any Ash action over many rows durably. A bulk action and its rows are
written in one transaction, then an Oban worker runs them. Rows that fail stay
behind with their errors, to correct and retry, and a bulk action survives a
restart or a lost node.

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

The library stands on Ash, Oban and Postgres. It has no screens and needs no
web framework.

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

Give Oban the queue and the two backstops:

```elixir
config :my_app, Oban,
  queues: [bulk_actions: 4],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", AshBulkDurable.Core.PurgeStaleStaging},
       {"*/5 * * * *", AshBulkDurable.Core.RescueStuckBulkActions}
     ]}
  ]
```

Oban's Lifeline plugin should run too: a job orphaned by a dead node stays
`:executing` without it.

## Other config

| Key | Default | |
|---|---|---|
| `:queue` | `:bulk_actions` | the Oban queue |
| `:default_chunk_size` | `50` | rows a per-row bulk action commits per batch |
| `:atomic_mode_max_rows` | `10_000` | the cap on an all-or-nothing bulk action |
| `:phase1_concurrency` | `4` | rows resolved at once |
| `:field_handlers` | `[]` | handlers tried before the built-in ones |
| `:disable_defaults` | `[]` | built-in handlers to drop |
| `:pubsub_module` | none | broadcasts each update on `"bulk_action:<id>"` |

## Telemetry

`[:ash_bulk_durable, :bulk_action | :staged_files_download | :phase1 | :chunk]`
spans, and `[:ash_bulk_durable, :worker_attempt, :start]`.

## License

MIT
