defmodule AshBulkDurable.Core.Storage do
  @moduledoc """
  What the core needs of the object store holding files staged before the
  worker runs: to read them, to list them, and to delete them. The worker
  downloads and deletes a bulk action's staged files; the orphan-staging
  sweep lists the staging prefix.

  Putting a file there and presigning a browser upload are its callers'. The package ships no adapter: the host names one
  that implements this behaviour,

      config :ash_bulk_durable,
        storage: MyApp.BulkActions.Storage
  """

  @callback get_object(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback delete_object(key :: String.t()) :: :ok | {:error, term()}

  @doc """
  Lists every staging object under `prefix`, each with its `last_modified`
  timestamp. Used by `AshBulkDurable.Core.PurgeStaleStaging` to age-gate the
  orphan sweep — the worker can't clean up keys for bulk actions whose submit
  transaction never committed, so the cron lists the prefix and deletes
  what's stale.
  """
  @callback list_objects(prefix :: String.t()) ::
              {:ok, [%{key: String.t(), last_modified: DateTime.t()}]} | {:error, term()}

  def get_object(key), do: impl().get_object(key)
  def delete_object(key), do: impl().delete_object(key)
  def list_objects(prefix), do: impl().list_objects(prefix)

  defp impl do
    AshBulkDurable.Core.config(:storage) ||
      raise """
      ash_bulk_durable needs a `:storage` adapter implementing `AshBulkDurable.Core.Storage`:

          config :ash_bulk_durable, storage: MyApp.BulkActions.Storage
      """
  end
end
