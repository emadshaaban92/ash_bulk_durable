defmodule AshBulkDurable.Core.PurgeStaleStaging do
  @moduledoc """
  Staged-file garbage collector. The worker deletes a bulk action's
  staging keys itself when it finishes `:completed`, and leaves them for a
  retry when it finishes `:completed_with_errors` or `:failed`. The worker
  never writes `:cancelled`: abandoning does (`AshBulkDurable.Core.abandon/2`),
  and deletes the files itself. Nothing deletes them for a bulk action that
  never ran, or whose delete was skipped or failed; `sweep/0` reclaims
  those.

  ## Daily sweep (`sweep/0`)

  Lists every object under the `bulk-staging/` prefix, keeps only those
  older than 24h, and decides per key against the set of keys that still
  need preservation:

    * **Key referenced by a `:queued` / `:running` /
      `:completed_with_errors` bulk action** → KEEP. An active worker may
      still need them, or a retry re-resolves the failed rows against them.
    * **Key referenced by a `:failed` bulk action that finished less than
      24h ago** → KEEP. Its owner can still retry it, and the retry
      downloads the same files. The day counts from `finished_at`, not
      from the upload, so a run that stayed queued or running for a day
      doesn't lose its files the moment it fails. Once they are gone, a
      retry can stage them again (`:staged_files` on
      `AshBulkDurable.Core.Retry.retry/2`), or its owner can abandon it.
    * **Everything else** → delete. That covers true orphans (the
      browser completed a presigned PUT but the submit transaction
      never committed) AND keys belonging to a worker-exited terminal
      bulk action (`:completed` / `:cancelled`, or `:failed` more than a
      day ago).

  The sweep is idempotent and takes no lock. The preserve-set comes from
  reading the unresolved bulk actions (same status set as the partial
  unique index on `BulkAction`, so at most one per user) plus those that
  failed within the day.

  `AshBulkDurable.Core.Poller` runs `sweep/0` on each node, every
  `:staging_sweep_interval`.

  ## Abandoning (`delete_staging/1`)

  Abandoning flips a `:completed_with_errors` or `:failed` bulk action to
  `:cancelled` long after the worker exited, so nothing on the worker's code path can
  drop its staged files. `AshBulkDurable.Core.abandon/2` calls
  `delete_staging/1` itself once the cancel commits; when it can't (the
  cancel ran inside a caller's transaction, or storage failed), the next
  sweep reclaims the `:cancelled` bulk action's files.
  """
  require Ash.Query

  alias AshBulkDurable.Core.Storage

  @staging_prefix "bulk-staging/"
  @stale_after_seconds 24 * 60 * 60

  @doc """
  Reads the bulk action with this id and deletes its staging keys (see
  `delete_staging/1`). A missing bulk action is a no-op.
  """
  def delete_bulk_action_staging(bulk_action_id) do
    case Ash.get(bulk_action_resource(), bulk_action_id, authorize?: false) do
      {:ok, bulk_action} ->
        delete_staging(bulk_action)

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Deletes every staging key in `bulk_action`'s `staged_files`, as the
  record holds them, without reading the bulk action again.
  """
  def delete_staging(bulk_action) do
    bulk_action.staged_files
    |> Map.values()
    |> Enum.each(&Storage.delete_file/1)

    :ok
  end

  # ── Daily sweep ────────────────────────────────────────────────────────

  @doc """
  Deletes every staged file older than a day that no unresolved or
  recently failed bulk action holds.
  """
  def sweep do
    case Storage.list_files(@staging_prefix) do
      {:ok, objects} ->
        cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)
        keep = keys_to_preserve(cutoff)
        Enum.each(objects, &maybe_purge(&1, keep, cutoff))

      {:error, _term} ->
        :ok
    end
  end

  defp maybe_purge(object, keep, cutoff) do
    if stale?(object, cutoff) and not MapSet.member?(keep, object.key) do
      Storage.delete_file(object.key)
    end
  end

  defp stale?(%{last_modified: %DateTime{} = last_modified}, cutoff) do
    DateTime.compare(last_modified, cutoff) != :gt
  end

  defp stale?(_object, _cutoff), do: false

  # Every staging key claimed by a bulk action whose status still warrants
  # preservation: one of the one-unresolved statuses (capped by the partial
  # unique index at one bulk action per user), or `:failed` within the last
  # day, while its owner can still retry it. Any staging key NOT in this set
  # (orphan or worker-exited terminal) is fair game to delete once it's past
  # the staleness cutoff.
  defp keys_to_preserve(cutoff) do
    bulk_action_resource()
    |> Ash.Query.filter(
      status in [:queued, :running, :completed_with_errors] or
        (status == :failed and finished_at > ^cutoff)
    )
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(&Map.values(&1.staged_files))
    |> MapSet.new()
  end

  defp bulk_action_resource, do: AshBulkDurable.Core.config(:bulk_action_resource)
end
