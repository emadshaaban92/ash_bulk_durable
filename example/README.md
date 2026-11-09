# AshBulkDurable example

A small Phoenix and AshPostgres app with a `/bulk` page over
[`ash_bulk_durable`](../README.md). Upload a sheet of books, map its columns,
run it, then correct and retry the rows that failed.

The library has no screens. The ones here are plain LiveView with no other
dependency, and they're meant to be copied into your app.

## Running it

Needs PostgreSQL 16+. It connects to `db` as `admin`/`admin` unless
`DATABASE_HOST`, `DATABASE_USER` and `DATABASE_PASSWORD` say otherwise.

```console
$ mix setup
$ mix phx.server     # http://localhost:4000
```

`mix test` runs the same flows without a browser. The resources it adds, such
as `Example.Test.Region`, live in `test/support`, with their tables in
`priv/test_repo`: shapes the example's own books and authors don't have.

There's no sign-in: `ExampleWeb.CurrentUser` picks the first seeded user, an
admin of the seeded organization.

Try this sheet with Book → Create, looking the author up by email:

```csv
isbn,title,pages,cover,author
1,The Dispossessed,387,front.png,ursula@example.test
2,Refused,0,front.png,ursula@example.test
```

Upload a ZIP holding `front.png` for the cover, and submit. The first row is
written, with its cover extracted from the ZIP. The second stops on its page
count. Download the errors sheet, fix it, and upload it under Retry with
corrections.

## Copying the screens

Take these into your app:

| From | What it is |
|---|---|
| `lib/example_web/bulk.ex` and `lib/example_web/bulk/` | the screens |
| `lib/example_web/live/bulk_live/index.ex` | your LiveView, a few lines |

Rename the `ExampleWeb` modules, then:

1. Point `ExampleWeb.Bulk.config/2` at your app, and list the resources `/bulk`
   offers:

   ```elixir
   config :my_app, :bulk, resources: [MyApp.Blog.Post]
   ```

   A resource needs an identity to be offered.

2. Add the route inside a `live_session` that assigns `@scope`:

   ```elixir
   live "/bulk", BulkLive.Index
   ```

3. Do the [library's setup](../README.md#setup): the `BulkAction` and `Row`
   resources, `Owner`, config and the poller. `lib/example/bulk_actions/` has
   all of them working, and `Example.Application` starts the poller.

4. Give `:storage` an adapter that also implements `ExampleWeb.Bulk.Storage`,
   for presigned uploads and the errors sheet. `LocalStorage` here builds on
   `AshBulkDurable.Storage.Local` to keep files on disk, and
   `StorageController` honours its signed URLs. Replace both with your object
   store on more than one node without a shared volume.

5. Add the `Put` uploader from `assets/js/app.js` to your `LiveSocket`, or use
   your store's own and change the `uploader:` name in `presign_companion/2`.

The page uses Tailwind and daisyUI classes, and strings go through your Gettext
backend. The example ships no translations: `mix gettext.extract` in your app
picks up the page's strings with your own. `ExampleWeb.Bulk.Utils` is the one
place to plug in your own labels.

## Files in a sheet

`Example.Types.StoredFile` marks a field as a file, or `{:array, StoredFile}` as
several. `Example.BulkActions.FileHandler` claims that field: its cell names
files, separated by `|`, and the column asks for a companion ZIP. `FileResolver`
extracts them through `AshBulkDurable.Sheet.BoundedZip` when the row runs, and
extracts them again if a sweep took them while the row waited for a correction.
Use `BoundedZip` for any archive a user supplies: it holds extraction to a byte
budget, whatever the archive claims about itself.

## Organizations

A bulk action runs where its owner acted when submitting it.
`Example.BulkActions.Owner` rebuilds that scope for the worker: the user as they
are now, holding their roles in that organization, and reaching nothing there
if they've left it. `User` is multitenant by organization, so a read in that
scope finds that organization's people.
