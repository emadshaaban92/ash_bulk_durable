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

  The sweep is idempotent. It reads the bulk actions holding the stale keys,
  and deletes the keys of those that read as releasable only under their
  locks (`AshBulkDurable.Core.BulkActionLock`), once each still is: a retry
  writes under the same lock, so one that reopened a long-`:failed` bulk
  action after that read, or holds its lock while the sweep runs, keeps its
  files. A retry or abandon that comes while the sweep holds the lock is
  refused, as either is while another transaction holds it. A key no bulk action
  holds is deleted without a lock.

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
  import Ash.Expr, only: [expr: 1]

  require Ash.Expr
  require Ash.Query

  alias AshBulkDurable.Core.{BulkActionLock, Storage}

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

        objects
        |> Enum.filter(&stale?(&1, cutoff))
        |> Enum.map(& &1.key)
        |> purge(cutoff)

      {:error, _term} ->
        :ok
    end
  end

  defp stale?(%{last_modified: %DateTime{} = last_modified}, cutoff) do
    DateTime.compare(last_modified, cutoff) != :gt
  end

  defp stale?(_object, _cutoff), do: false

  defp purge([], _cutoff), do: :ok

  # Groups the stale keys by the bulk actions holding them. A key nobody
  # holds is deleted outright. The keys of a group whose holders all read as
  # releasable are deleted under the holders' locks, and only once each still
  # is, so a retry committed since the read, or in flight, keeps them.
  defp purge(keys, cutoff) do
    holders = holders(keys)

    keys
    |> Enum.group_by(&(holders |> Map.get(&1, []) |> Enum.sort_by(fn holder -> holder.id end)))
    |> Enum.each(fn
      {[], keys} ->
        Enum.each(keys, &Storage.delete_file/1)

      {holders, keys} ->
        if Enum.all?(holders, &releasable?(&1, cutoff)),
          do: delete_under_locks(Enum.map(holders, & &1.id), keys, cutoff)
    end)
  end

  # `%{key => [bulk_action]}`: every bulk action whose `staged_files` names
  # one of `keys`, whatever its status.
  defp holders(keys) do
    bulk_action_resource()
    |> Ash.Query.filter(
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_each_text(?) AS staged(name, key) WHERE staged.key = ANY(?))",
        staged_files,
        type(^keys, {:array, :string})
      )
    )
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(fn bulk_action ->
      Enum.map(Map.values(bulk_action.staged_files), &{&1, bulk_action})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The statuses whose files the sweep may delete (see the moduledoc), a
  # `:failed` one's only once it failed over a day ago.
  @released [:completed, :failed, :cancelled]

  defp releasable?(%{status: :failed, finished_at: %DateTime{} = finished_at}, cutoff),
    do: DateTime.compare(finished_at, cutoff) != :gt

  defp releasable?(%{status: status}, _cutoff), do: status in @released

  # Holds every holder's lock (`AshBulkDurable.Core.BulkActionLock`) while
  # its status still releases its files, and deletes the keys with the locks
  # held. A retry takes the same lock before it writes, so it either
  # committed first, and the holder no longer matches, or is refused at once
  # while the delete holds it, as is an abandon. A holder another transaction has locked, such
  # as a retry's, keeps its files to the next sweep.
  defp delete_under_locks(ids, keys, cutoff) do
    Ash.transaction([bulk_action_resource()], fn ->
      released =
        expr(status != :failed or is_nil(finished_at) or finished_at <= ^cutoff)

      if Enum.all?(ids, &match?({:ok, _}, BulkActionLock.lock(&1, @released, filter: released))),
        do: Enum.each(keys, &Storage.delete_file/1)
    end)
  end

  defp bulk_action_resource, do: AshBulkDurable.Core.config(:bulk_action_resource)
end
