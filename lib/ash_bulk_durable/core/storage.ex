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
  its callers'. The host names the module that implements this behaviour:
  the disk store the package ships outside the core (see the README), or
  one of its own,

      config :ash_bulk_durable,
        storage: MyApp.BulkActions.Storage

  Every callback takes `opts`, a keyword list the core leaves empty today,
  so a store can read overrides from it later without a new arity.
  """

  @typedoc "A key in the store, such as `bulk-staging/<owner>/<uuid>/images.zip`."
  @type key :: String.t()

  @doc """
  Writes the file stored at `key` to `path`, a file the worker created and
  removes when it is done. The file is already there, empty, so the store
  overwrites it. Answers `:ok` once the whole file is there.
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
  what's stale. The core passes a prefix ending in `/` (`bulk-staging/`), so
  a store may read it as a directory or as the start of every key.
  """
  @callback list_files(prefix :: String.t(), opts :: keyword()) ::
              {:ok, [%{key: key(), last_modified: DateTime.t()}]} | {:error, term()}

  @doc """
  Checks the store's own configuration, so a node that cannot use it fails
  when `AshBulkDurable.Core.Poller` starts rather than at its first sweep or
  fetch. Optional; a store without it is taken as configured.
  """
  @callback check_config(opts :: keyword()) :: :ok | {:error, String.t()}

  @optional_callbacks check_config: 1

  def fetch_file(key, path), do: impl().fetch_file(key, path, [])
  def delete_file(key), do: impl().delete_file(key, [])
  def list_files(prefix), do: impl().list_files(prefix, [])

  @doc """
  Raises `ArgumentError` when the configured store says its configuration
  is wrong. Does nothing when no store is configured, or when it has no
  `c:check_config/1`.
  """
  def check_config! do
    with store when not is_nil(store) <- AshBulkDurable.Core.config(:storage),
         true <- Code.ensure_loaded?(store) and function_exported?(store, :check_config, 1),
         {:error, message} <- store.check_config([]) do
      raise ArgumentError,
            "ash_bulk_durable: the `:storage` module #{inspect(store)} " <>
              "is not configured: #{message}"
    end

    :ok
  end

  defp impl do
    AshBulkDurable.Core.config(:storage) ||
      raise """
      ash_bulk_durable needs a `:storage` module implementing `AshBulkDurable.Core.Storage`:

          config :ash_bulk_durable, storage: MyApp.BulkActions.Storage
      """
  end
end
