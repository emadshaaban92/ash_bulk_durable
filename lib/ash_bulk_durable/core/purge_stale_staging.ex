defmodule AshBulkDurable.Core.PurgeStaleStaging do
  @moduledoc """
  Staged-file garbage collector. The worker deletes a bulk action's
  staging keys itself when it finishes `:completed` or `:cancelled`, and
  leaves them for a retry when it finishes `:completed_with_errors` or
  `:failed`; it can't reach states where it never ran or already exited.
  This cron reclaims those.

  ## Daily sweep (`perform/1` with no `bulk_action_id`)

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
      bulk action (`:completed` / `:failed` / `:cancelled`): a `:failed`
      one can be retried for a day, its files gone after that.

  The preserve-set comes from reading bulk actions whose status is in the
  one-unresolved set (same status set as the partial unique index on
  `BulkAction`). The identity bounds that read to at most one row per
  user, so memory is O(unresolved users), not O(bulk action history).

  ## Eager one-shot (`perform/1` with a `bulk_action_id`, or `delete_bulk_action_staging/1`)

  The Abandon path flips a `:completed_with_errors` bulk action to
  `:cancelled` long after the worker exited, so nothing on the bulk action's own
  code path can purge its staging. The Abandon action enqueues a one-shot
  `new(%{bulk_action_id: id})` job that calls `delete_bulk_action_staging/1` to drop the
  keys immediately; if that job is lost, the daily sweep catches the
  `:cancelled` bulk action on its next pass.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  require Ash.Query

  alias AshBulkDurable.Core.Storage

  @staging_prefix "bulk-staging/"
  @stale_after_seconds 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"bulk_action_id" => bulk_action_id}})
      when is_binary(bulk_action_id) do
    delete_bulk_action_staging(bulk_action_id)
    :ok
  end

  def perform(%Oban.Job{}) do
    sweep()
    :ok
  end

  @doc """
  Synchronously deletes every staging key recorded on the given bulk action.
  Safe to call for a missing bulk action (no-op) — the bulk action row may have been
  destroyed before the eager job ran.
  """
  def delete_bulk_action_staging(bulk_action_id) do
    case Ash.get(bulk_action_resource(), bulk_action_id, authorize?: false) do
      {:ok, bulk_action} ->
        bulk_action.staged_files
        |> Map.values()
        |> Enum.each(&Storage.delete_object/1)

        :ok

      {:error, _} ->
        :ok
    end
  end

  # ── Daily sweep ────────────────────────────────────────────────────────

  defp sweep do
    case Storage.list_objects(@staging_prefix) do
      {:ok, objects} ->
        keep = keys_to_preserve()
        cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)
        Enum.each(objects, &maybe_purge(&1, keep, cutoff))

      {:error, _term} ->
        :ok
    end
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
  defp keys_to_preserve do
    bulk_action_resource()
    |> Ash.Query.filter(status in [:queued, :running, :completed_with_errors])
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(&Map.values(&1.staged_files))
    |> MapSet.new()
  end

  defp bulk_action_resource, do: AshBulkDurable.Core.config(:bulk_action_resource)
end
