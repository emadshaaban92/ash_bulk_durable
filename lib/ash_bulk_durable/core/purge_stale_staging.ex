defmodule AshBulkDurable.Core.PurgeStaleStaging do
  @moduledoc """
  Staged-file garbage collector. The worker deletes a bulk action's
  staging keys itself when it finishes `:completed`, abandoning one deletes
  its keys once the cancel commits, and a bulk action that finishes
  `:completed_with_errors` or `:failed` keeps them for a retry. What none of
  those reach, `sweep/0` reclaims.

  `AshBulkDurable.Core.Poller` runs the sweep every
  `:staging_sweep_interval` (a day by default) on each node. It holds no
  lock and no transaction while it lists and deletes: deleting is
  idempotent, so nodes sweeping at once only repeat each other. A host that
  runs no poller can call `sweep/0` on its own schedule.

  ## The sweep

  Lists every object under the `bulk-staging/` prefix, keeps only those
  older than 24h, and decides per key against the set of keys that still
  need preservation:

    * **Key referenced by a `:queued` / `:running` /
      `:completed_with_errors` bulk action** → KEEP. An active worker may still
      need them, or the retry-in-place re-resolves the `:failed`
      rows against them.
    * **Everything else** → delete. That covers true orphans (the
      browser completed a presigned PUT but the submit transaction
      never committed) AND keys belonging to a worker-exited terminal
      bulk action (`:completed` / `:failed` / `:cancelled`).
    * **Key of a bulk action that failed less than a day ago** → KEEP, so
      it can be retried for a day from when it failed, not from when its
      files were uploaded.

  The preserve-set comes from reading bulk actions whose status is in the
  one-unresolved set (same status set as the partial unique index on
  `BulkAction`), at most one per user, and those that failed in the last
  day: bounded by recent activity, not by the bulk action history.
  """

  require Ash.Query

  alias AshBulkDurable.Core.Storage

  @staging_prefix "bulk-staging/"
  @stale_after_seconds 24 * 60 * 60

  @doc """
  Synchronously deletes every staging key recorded on the given bulk action.
  Safe to call for a missing bulk action (no-op).
  """
  def delete_bulk_action_staging(bulk_action_id) do
    case Ash.get(bulk_action_resource(), bulk_action_id, authorize?: false) do
      {:ok, bulk_action} -> delete_staging(bulk_action)
      {:error, _} -> :ok
    end
  end

  @doc "Deletes every staging key recorded on `bulk_action`."
  def delete_staging(bulk_action) do
    bulk_action.staged_files
    |> Map.values()
    |> Enum.each(&Storage.delete_object/1)
  end

  # ── Sweep ──────────────────────────────────────────────────────────────

  @doc "Deletes every staged file older than a day that no unresolved bulk action holds."
  def sweep do
    case Storage.list_objects(@staging_prefix) do
      {:ok, objects} ->
        cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)
        keep = keys_to_preserve(cutoff)
        Enum.each(objects, &maybe_purge(&1, keep, cutoff))

      {:error, _term} ->
        :ok
    end

    :ok
  end

  defp maybe_purge(object, keep, cutoff) do
    if stale?(object, cutoff) and not MapSet.member?(keep, object.key) do
      Storage.delete_object(object.key)
    end
  end

  defp stale?(%{last_modified: %DateTime{} = last_modified}, cutoff) do
    DateTime.compare(last_modified, cutoff) != :gt
  end

  defp stale?(_object, _cutoff), do: false

  # Every staging key claimed by a bulk action whose status still warrants
  # preservation — i.e. one of the one-unresolved statuses. The partial
  # unique index caps this at one bulk action per user, so the set is bounded by
  # the active-user count, not the bulk action history. Any staging key NOT
  # in this set (orphan or worker-exited terminal) is fair game to
  # delete once it's past the staleness cutoff.
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
