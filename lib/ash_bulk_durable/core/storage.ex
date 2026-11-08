defmodule AshBulkDurable.Core.Storage do
  @moduledoc """
  What the core needs of the store holding files staged before the worker
  runs, worded as what it wants done rather than as one store's operations:

    * `c:fetch_file/3` — write a staged file to a local path the worker
      hands over, so a large file never has to sit in memory.
    * `c:delete_file/2` — drop a staged file once nothing needs it.
    * `c:list_files/2` — list what is staged under a prefix, for the
      orphan-staging sweep.

  Putting a file there and handing the browser somewhere to upload it are
  its callers'. The package ships no store: the host names a module that
  implements this behaviour,

      config :ash_bulk_durable,
        storage: MyApp.BulkActions.Storage

  Every callback takes `opts`, a keyword list the core leaves empty today,
  so a store can read overrides from it later without a new arity.
  """

  @typedoc "A key in the store, such as `bulk-staging/<owner>/<uuid>/images.zip`."
  @type key :: String.t()

  @doc """
  Writes the file stored at `key` to `path`, a file the worker created and
  removes when it is done. Answers `:ok` once the whole file is there.
  A missing key, or any other failure, is `{:error, term}`.
  """
  @callback fetch_file(key(), path :: Path.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc "Deletes the file at `key`. A key that is already gone is `:ok`."
  @callback delete_file(key(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Lists every file stored under `prefix`, each with its `last_modified`
  timestamp. Used by `AshBulkDurable.Core.PurgeStaleStaging` to age-gate the
  orphan sweep — the worker can't clean up keys for bulk actions whose submit
  transaction never committed, so the sweep lists the prefix and deletes
  what's stale.
  """
  @callback list_files(prefix :: String.t(), opts :: keyword()) ::
              {:ok, [%{key: key(), last_modified: DateTime.t()}]} | {:error, term()}

  def fetch_file(key, path), do: impl().fetch_file(key, path, [])
  def delete_file(key), do: impl().delete_file(key, [])
  def list_files(prefix), do: impl().list_files(prefix, [])

  defp impl do
    AshBulkDurable.Core.config(:storage) ||
      raise """
      ash_bulk_durable needs a `:storage` module implementing `AshBulkDurable.Core.Storage`:

          config :ash_bulk_durable, storage: MyApp.BulkActions.Storage
      """
  end
end
