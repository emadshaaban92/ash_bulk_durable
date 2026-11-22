defmodule AshBulkDurable.Core.Retention do
  @moduledoc """
  Deletes the bulk actions that finished longer ago than `:retention`, and
  their rows with them. Off unless `:retention` is set: by default every
  bulk action and row is kept for good.

  `AshBulkDurable.Core.Poller` runs `prune/1` on each node, every
  `:staging_sweep_interval`, just before the staged-file sweep
  (`AshBulkDurable.Core.PurgeStaleStaging.sweep/0`).

  ## What it deletes

  A bulk action `:completed`, `:failed` or `:cancelled` whose `finished_at`
  is more than `:retention` milliseconds ago on the database's clock. Its
  rows go with it: their foreign key cascades. A `:failed` one could still
  have been retried until then.

  It never deletes one `:queued` or `:running`, nor one
  `:completed_with_errors`: that one waits for its owner to retry or
  abandon it, and holds their one unresolved slot meanwhile, so there is at
  most one per owner. Abandoned, it is `:cancelled`, and goes once it has
  been for `:retention`.

  Its staged files are left to the staged-file sweep, which deletes a
  finished bulk action's files once they are a day old, whether or not the
  bulk action is still there.

  The delete broadcasts nothing, so a page open on a bulk action just
  pruned shows it until it reloads, and a retry or abandon from there is
  refused as for any bulk action no longer there.

  ## One at a time

  It reads the ids of up to 100 bulk actions due, in random order and
  without locking them, then deletes each in a transaction of its own: it
  locks that one by its primary key with `FOR UPDATE SKIP LOCKED`, reading
  again that it is still due, and deletes it. Then it reads the next batch,
  until none is due. One bulk action can hold many rows, all deleted with
  it, so a transaction never holds more than one bulk action's. Each read
  of the due ones scans them once, so a first prune over a long history
  scans them once per 100 deleted rather than once per bulk action.

  A bulk action another transaction holds, such as a retry's under the bulk
  action lock (`AshBulkDurable.Core.BulkActionLock`), is skipped, and its
  status is read again once locked: a retry committed meanwhile has moved
  it to `:queued`, and it is kept. Nodes pruning at once split the bulk
  actions between them.

  A delete that fails, such as one a host table's foreign key to
  `bulk_actions` refuses because it doesn't cascade, rolls back that bulk
  action alone and is logged, and the prune goes on with the others. Its
  transaction checks deferred constraints at the delete
  (`SET CONSTRAINTS ALL IMMEDIATE`), so a host's foreign key declared
  `DEFERRABLE INITIALLY DEFERRED` refuses it there too, rather than at the
  commit, where it would end the prune. This prune doesn't try a skipped or
  failed bulk action again, so it always ends, and such a bulk action never
  holds up the ones behind it.

  It deletes with a query of its own, not through an action of the bulk
  action resource, so a host's policies and its own `:destroy` action (if
  any) play no part.
  """
  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Ash.Sort
  require Logger

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.BulkActionLock

  @finished [:completed, :failed, :cancelled]
  @batch 100

  @doc """
  Deletes every bulk action that finished `retention` milliseconds ago or
  more (see the moduledoc), one per transaction, and returns how many it
  deleted. One whose delete fails is logged and kept. `nil`, the
  `:retention` config's default, deletes nothing.

  Raises `ArgumentError` when `retention` is neither `nil` nor a positive
  integer.
  """
  def prune(retention \\ Core.config(:retention))

  def prune(nil), do: 0

  def prune(retention) do
    validate!(retention)
    prune_batches(retention, [], 0)
  end

  @doc false
  def validate!(nil), do: nil
  def validate!(retention) when is_integer(retention) and retention > 0, do: retention

  def validate!(retention) do
    raise ArgumentError,
          "ash_bulk_durable: :retention must be nil or a positive number of milliseconds, " <>
            "got: #{inspect(retention)}"
  end

  # Each id of a batch is deleted, or added to `passed`, which later batches
  # leave out: every batch takes ids no earlier one did, so this always ends.
  defp prune_batches(retention, passed, deleted) do
    case due_ids(retention, passed) do
      [] ->
        deleted

      ids ->
        {passed, deleted} = Enum.reduce(ids, {passed, deleted}, &prune_id(retention, &1, &2))
        prune_batches(retention, passed, deleted)
    end
  end

  defp prune_id(retention, id, {passed, deleted}) do
    case prune_one(retention, id) do
      :deleted -> {passed, deleted + 1}
      :passed -> {[id | passed], deleted}
    end
  end

  # Unlocked: each id is locked, and read again as due, by `prune_one/2`.
  defp due_ids(retention, passed) do
    Core.config(:bulk_action_resource)
    |> due(retention)
    |> Ash.Query.filter(id not in ^passed)
    |> Ash.Query.sort(Ash.Sort.expr_sort(fragment("random()"), :float))
    |> Ash.Query.limit(@batch)
    |> Ash.Query.select([:id])
    |> BulkActionLock.pin()
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  # `:deleted`, or `:passed` when another transaction holds it, it is no
  # longer due, or its delete failed.
  defp prune_one(retention, id) do
    resource = Core.config(:bulk_action_resource)
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)

    repo.transaction(fn ->
      if locked?(resource, retention, id), do: delete(resource, repo, id), else: :passed
    end)
    |> case do
      {:ok, result} -> result
      {:error, :failed} -> :passed
    end
  end

  defp locked?(resource, retention, id) do
    resource
    |> due(retention)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id])
    |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
    |> BulkActionLock.pin()
    |> Ash.read_one!(authorize?: false)
    |> is_struct()
  end

  defp due(query, retention) do
    Ash.Query.filter(
      query,
      status in ^@finished and
        finished_at <=
          fragment(
            "((now() AT TIME ZONE 'utc') - (? * interval '1 millisecond'))",
            ^retention
          )
    )
  end

  # A failed delete has aborted the transaction: it rolls back, this bulk
  # action alone, and the prune goes on. Deferred constraints are checked
  # here, not at the commit, so a deferred foreign key's refusal lands here
  # too.
  defp delete(resource, repo, id) do
    table = AshPostgres.DataLayer.Info.table(resource)
    prefix = AshPostgres.DataLayer.Info.schema(resource)

    repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

    repo.delete_all(
      from(bulk_action in table, where: bulk_action.id == type(^id, Ecto.UUID)),
      prefix: prefix
    )

    :deleted
  rescue
    exception ->
      Logger.error(
        "ash_bulk_durable: the retention prune could not delete bulk action #{id}, " <>
          "so it keeps it: #{Exception.message(exception)}"
      )

      repo.rollback(:failed)
  end
end
