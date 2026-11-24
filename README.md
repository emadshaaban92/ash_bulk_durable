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

## How it works

1. **Submit.** A verb writes the bulk action, `:queued`, and a row for each
   input in one transaction, and returns. A sheet's columns are mapped to
   inputs first.
2. **Start.** The poller of the node it was submitted on starts it at once if
   it has a free slot, and any node's poller does within `:poll_interval`.
   The run locks the bulk action's row and sets it `:running`.
3. **Resolve.** Rows whose input holds a reference
   (`AshBulkDurable.Core.Reference`: a lookup of a record by an identity, or a
   resolver's value, such as a staged file) have it resolved, up to
   `:phase1_concurrency` at once and outside the lock, and each is saved
   `:resolved`, or `:failed` with its error.
4. **Write.** The rows then run the target action as the owner, in chunks of
   `:chunk_size` rows (`:default_chunk_size`, 50, by default). Each chunk is
   one transaction that locks the bulk action's row first, writes the chunk's
   rows, marks them `:succeeded` and adds them to `rows_done`. A chunk with a failing row rolls back, and its rows
   run again in halves until the failing ones are marked `:failed` alone. An
   `:all_or_nothing` bulk action writes every row in one transaction instead.
5. **Verdict.** Once no row is left to write, the run sets the bulk action
   `:completed`, or `:completed_with_errors` when some rows failed. A run that
   can't go on sets it `:failed` (an owner who lost access, or an
   all-or-nothing bulk action with a failed row; `AshBulkDurable.Core.Worker`
   lists every reason). Its owner can then `AshBulkDurable.retry/2` it,
   which reruns every row that has not succeeded, as it is or corrected, as
   the next pass, or `AshBulkDurable.abandon/2` it (`:cancelled`).

The rows' statuses are the run's progress, so a run that dies is started
again from where they stand. A run stamps the bulk action's `alive_at` as it
goes; once that is older than `:stale_after`, any node's poller starts it
again. Two runs of one bulk action may overlap, but each chunk takes the lock
and reads its rows under it, so they take turns and no row is written twice.
Runs that keep dying are counted, and end in a failed row or bulk action
rather than restarting forever.

## Installation

```elixir
def deps do
  [
    {:ash_bulk_durable, github: "emadshaaban92/ash_bulk_durable"}
  ]
end
```

With [igniter](https://hexdocs.pm/igniter) in your deps,
`mix ash_bulk_durable.install` then does the setup below for an app with an
Ecto repo: a domain with the two resources and their policies, an owner
module, the config with `AshBulkDurable.Storage.Local`, `AshBulkDurable` last
in the supervision tree, a SAT solver for the policies if the app has none,
and a migration through `mix ash.codegen`.
`--domain`, `--repo` and `--user` change what it names. It is safe to run
again, and leaves alone what is already there: a `:storage` already set, or
an `AshBulkDurable.Core.Poller` the tree already starts, which it tells you to
replace with `AshBulkDurable`. Read the owner it writes before you use it: it
reads the actor back by a UUID id, and a bulk action submitted in a tenant
fails when it runs (`:access_revoked`) until you say who may act there.

CSV and XLSX need no system packages. An XLSX is read by
[calamine](https://github.com/tafia/calamine), a Rust library, through
`spreadsheet`'s precompiled NIF, downloaded at compile time for the common
Linux, macOS and Windows targets.

## Setup

Your app owns a domain and two resources, which the library's extensions fill
in. Keep the policies: without them, anything that reaches the domain, such as
an AshJsonApi or AshGraphql endpoint or an admin screen, reads every user's
bulk actions and rows, and can call the engine's own actions on them.

```elixir
defmodule MyApp.BulkActions do
  use Ash.Domain

  resources do
    resource MyApp.BulkActions.BulkAction
    resource MyApp.BulkActions.Row
  end
end

defmodule MyApp.BulkActions.BulkAction do
  use Ash.Resource,
    domain: MyApp.BulkActions,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshBulkDurable.Core.Resource.BulkAction]

  postgres do
    table "bulk_actions"
    repo MyApp.Repo

    identity_wheres_to_sql one_unresolved_per_user:
                             "status IN ('queued', 'running', 'completed_with_errors')"
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end
end

defmodule MyApp.BulkActions.Row do
  use Ash.Resource,
    domain: MyApp.BulkActions,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshBulkDurable.Core.Resource.Row]

  postgres do
    table "bulk_action_rows"
    repo MyApp.Repo
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(bulk_action.user_id == ^actor(:id))
    end
  end
end
```

`user_id` holds what your `AshBulkDurable.Core.Owner` returns as the owner's
worker key; compare it with whatever in your actor that is. The engine's own
reads and writes don't go through these policies, so they decide only what
everyone else may do: here, read their own bulk actions and rows, and nothing
more. Every other action the extensions add (`:create`, `:mark_finished`,
`:enqueue_retry` and the rest) is the engine's, and no policy allows it.

The extensions add a `:read` but no `:destroy`, since destroying a bulk action
takes its rows with it, running or not. Declare `defaults [:destroy]` (or your
own) in `actions` if you want one, with a policy that allows it only where you
mean it to.

The attributes a page shows are public: on a bulk action `id`, `user_id`,
`resource_name`, `action_name`, `action_type`, `status`, `mode`,
`total_rows`, `rows_done`, `pass`, `error`, `result`, `metadata`,
`started_at`, `finished_at`, `inserted_at` and `updated_at`; on a row `id`,
`bulk_action_id`, `row_index`, `status`, `error`, `refused`, `record_id`,
`metadata` and `inserted_at`. The rest are the engine's and not public, so an
API layer doesn't serve or filter on them: the stored inputs and targets, the
tenant, staged-file keys, resolved references, the liveness stamp and the
crash counters. They are still loaded on every record your code reads.

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
  worker acts as them again. It refuses (`{:error, reason}`) an owner who can
  no longer act in the bulk action's tenant, since every row that names no
  tenant of its own is written there whatever the scope says. It is checked
  when a run starts and again before every chunk, and fails the bulk action
  before the next row runs; rows earlier chunks wrote stay written. Each
  chunk runs with the scope rebuilt for it, so new roles apply from the next
  chunk on.
- `AshBulkDurable.Core.Storage` fetches, deletes and lists staged files. The
  worker has each staged file written to a temporary file, so a large one is
  never held in memory. `AshBulkDurable.Storage.Local` keeps them on the
  server's disk, under a configured `:root`, for an app on one node or on
  several that share a volume:

  ```elixir
  config :ash_bulk_durable, storage: AshBulkDurable.Storage.Local
  config :ash_bulk_durable, AshBulkDurable.Storage.Local, root: "/var/lib/my_app/bulk_files"
  ```

  On several nodes without a shared volume, a run can start on a node that
  doesn't hold its files, and the rows that need them fail; use an object
  store there. `AshBulkDurable.Storage.S3` keeps them in an S3 bucket (or any
  store speaking the S3 API) through `ExAws`, once the app depends on
  `:ex_aws`, `:ex_aws_s3`, `:sweet_xml` and an HTTP client such as
  `:hackney`:

  ```elixir
  config :ash_bulk_durable, storage: AshBulkDurable.Storage.S3
  config :ash_bulk_durable, AshBulkDurable.Storage.S3, bucket: "my-app-bulk-files"
  ```

Two keys are read when your resources compile, not when the app runs:
`:bulk_action_resource`, which the row's `bulk_action` relationship points
at, and `:pubsub_module`, which fills in the bulk action's `pub_sub` block.
Set them in `config/config.exs` (or a file it imports), not in
`config/runtime.exs`. Without `:bulk_action_resource` the row resource fails
to compile; a bulk action resource compiled without `:pubsub_module`
broadcasts no updates, though the progress hints, read when they are sent,
still go out. A release keeps what the resources were built with, whatever
its runtime config says. Every other key is read when it is used, so
`config/runtime.exs` can set it.

Add `AshBulkDurable` last to each node's supervision tree, after the repo,
anything that migrates it, and the PubSub and endpoint a run broadcasts
through. It supervises the node's poller, which then stops first, so the runs
it lets finish on shutdown can still broadcast:

```elixir
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Endpoint,
  AshBulkDurable
]
```

Its child spec checks the config before anything starts: a node whose config
misses one of the four keys above, names a module that isn't the right kind,
or whose storage says its own config is wrong (a disk store without a `:root`)
fails at boot with an `ArgumentError` saying so. So does an option the poller
doesn't know, or a value of the wrong kind. Give the poller options with
`{AshBulkDurable, poller: [max_running: 4]}`, or none with `{AshBulkDurable,
poller: false}` on a node that leaves running bulk actions to others, which
still checks the config. `AshBulkDurable.Core.Poller` can also go in the tree
by itself, with the same checks.

The poller starts each queued bulk action as soon as it is submitted or
retried on its node, and every few seconds starts any other node's: one
queued, or one whose run died with its node. It also runs the daily sweep of staged files, and,
when `:retention` is set, deletes the bulk actions that finished longer ago
than that, with their rows. Without a poller, bulk actions stay queued and a
warning is logged once; set `warn_without_poller: false` on nodes that leave
the work to others, and in tests, which run bulk actions with
`AshBulkDurable.Core.Worker.run_now/1` or `drain/0`.

Its options, each also an `:ash_bulk_durable` config key, which is checked the
same way:

| Option | Default | |
|---|---|---|
| `:poll_interval` | 5 seconds | how often it looks for bulk actions to start |
| `:max_running` | `2` | bulk actions this node runs at once |
| `:stale_after` | 2 minutes | how long a running bulk action's liveness hint may go unstamped before another run starts it |
| `:staging_sweep_interval` | a day | between staged-file sweeps and retention prunes; `nil` for none |
| `:retention` | `nil`, keep all | how long a bulk action is kept once it finished `:completed`, `:failed` or `:cancelled`; then it is deleted with its rows |
| `:shutdown_grace` | 20 seconds | how long a run still going at shutdown has to finish before it is killed |

Bulk actions and their rows are kept for good unless you set `:retention`, in
milliseconds:

```elixir
config :ash_bulk_durable, retention: :timer.hours(24 * 30)
```

The prune never deletes a bulk action that is `:completed_with_errors`: that one
waits for its owner to retry or abandon it. A `:failed` one can be retried only
until the prune deletes it. It deletes one bulk action per transaction, picked
at random, with its own query, not through the resource's actions or policies.
One that a table of yours references without `on_delete: :delete` can't be
deleted: the prune logs an error, keeps it, and goes on with the others.

A run stamps its bulk action's liveness hint (`alive_at`) as it goes, and at
least every `:alive_interval` (30 seconds by default). Two runs of one bulk
action are harmless, since each chunk runs under the bulk action's row lock,
so the hint only decides when to start one. Each running bulk action takes one
connection, up to `:phase1_concurrency` more while it resolves references, and
one more for its ticker's stamp, held briefly each `:alive_interval`: size the
repo's pool for `:max_running` times `:phase1_concurrency + 2`.

## What is and isn't guaranteed

Guaranteed, for every target resource in the bulk action's repo:

- **A submit is all or nothing.** The bulk action and every one of its rows
  are written in one transaction, or none are.
- **A row's database writes commit once, with its status.** A chunk's target
  writes share the transaction that holds the bulk action's lock and flips
  its rows to `:succeeded` or `:failed`. A row that succeeds has its writes
  committed exactly once; a row that fails has none, since they roll back
  with it. Two runs of one bulk action may overlap, and a run may outlive a
  retry, without a row being applied twice.
- **One verdict per pass.** Each run of a bulk action (each pass, a retry
  starting the next) ends `:completed`, `:completed_with_errors`, `:failed`
  or `:cancelled` once.
- **An `:all_or_nothing` bulk action** commits every row or none.
- **It finishes.** A bulk action survives a restart or a lost node, as
  another node resumes it. One whose runs keep dying fails as `:crashed`, a
  row that keeps killing its run fails alone as crashed, and setup that keeps
  raising fails the bulk action; none restart forever.
- **The worker acts as the owner.** Rows run with the scope
  `AshBulkDurable.Core.Owner` rebuilds, so the target's policies apply as
  they would to the owner, and a bulk action can do nothing its owner
  couldn't.

Not guaranteed:

- **Side effects outside the database may run more than once, and for rows
  that end failed.** A per-row chunk with a bad row rolls back and
  runs its rows again in halves, a run that dies mid-chunk runs the chunk
  again, and a reference's resolver (`AshBulkDurable.Core.Resolver`) can run
  again for a row it already resolved. A target action that sends an email,
  calls an API or publishes a message from a change or hook does so each
  time. Make that idempotent, or have the action write it to a table in the
  same repo, which commits with the row or not at all, and send it from
  there.
- **Writes to another repo.** A target in another repo writes outside the
  lock, so none of the above holds for it (see Setup).
- **Lookups are not re-checked.** References are resolved before the chunk's
  transaction opens, outside the lock; the row then writes with what they
  resolved to, even if the record a lookup found has changed since.
- **Progress hints** are best effort: one may be lost, or arrive late or from
  an older pass.
- **When a bulk action starts.** A node starts one submitted there as soon
  as it has a free slot, and any other within `:poll_interval`; one whose
  node died waits up to `:stale_after`. Bulk actions start oldest first,
  with no priority and no fairness between owners.
- **Stopping one that's running.** `AshBulkDurable.abandon/2` takes only a
  bulk action that finished with failed rows, or failed outright.

## Other config

| Key | Default | |
|---|---|---|
| `:alive_interval` | 30 seconds | how often a run stamps its liveness hint |
| `:max_stalled_starts` | `3` | starts in a row without progress before a bulk action's rows run alone |
| `:max_row_attempts` | `2` | runs that may die on a row run alone before it fails as crashed; a per-row bulk action whose stalled starts pass `:max_stalled_starts` + `:max_row_attempts` + `:max_setup_failures` (its runs dying before any row) fails with `reason: :crashed` |
| `:max_setup_failures` | `3` | starts that raise before reaching a row, or find its resource, action or stored terms missing on their node (as during a rolling deploy), with no progress between, before a bulk action fails; one missing them fails with `reason: :gone` or `:unreadable` |
| `:warn_without_poller` | `true` | warn when a bulk action is queued on a node with no poller |
| `:default_chunk_size` | `50` | rows a per-row bulk action commits per batch |
| `:halving_min_rows` | `8` | a failed chunk's rows are halved down to sets this small, then run row by row; `0` runs every row alone |
| `:max_rows` | `100_000` | the most rows a bulk action holds, in either mode |
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
