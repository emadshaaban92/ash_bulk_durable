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

  It deletes one bulk action per transaction, picked at random among those
  due, with `FOR UPDATE SKIP LOCKED`, until none is left. One bulk action can
  hold many rows, all deleted with it, so a transaction never holds more
  than one bulk action's. A bulk action another transaction holds, such as
  a retry's under the bulk action lock (`AshBulkDurable.Core.BulkActionLock`),
  is skipped, and its status is read again once locked: a retry committed
  meanwhile has moved it to `:queued`, and it is kept. Nodes pruning at once
  split the bulk actions between them.

  A delete that fails, such as one a host table's foreign key to
  `bulk_actions` refuses because it doesn't cascade, rolls back that bulk
  action alone and is logged, and the prune goes on with the others; this
  prune doesn't pick that one again. Picked at random, such a bulk action
  never holds up the ones behind it, at this prune or the next.

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
    prune_each(retention, [], 0)
  end

  @doc false
  def validate!(nil), do: nil
  def validate!(retention) when is_integer(retention) and retention > 0, do: retention

  def validate!(retention) do
    raise ArgumentError,
          "ash_bulk_durable: :retention must be nil or a positive number of milliseconds, " <>
            "got: #{inspect(retention)}"
  end

  # Each turn deletes a bulk action, or adds one to `failed`, which the next
  # turns never pick: this always ends.
  defp prune_each(retention, failed, deleted) do
    case prune_one(retention, failed) do
      :none -> deleted
      :deleted -> prune_each(retention, failed, deleted + 1)
      {:failed, id} -> prune_each(retention, [id | failed], deleted)
    end
  end

  defp prune_one(retention, failed) do
    resource = Core.config(:bulk_action_resource)
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)

    repo.transaction(fn ->
      case pick(resource, retention, failed) do
        nil -> :none
        id -> delete(resource, repo, id)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, {:failed, _id} = failed} -> failed
    end
  end

  defp pick(resource, retention, failed) do
    resource
    |> Ash.Query.filter(
      status in ^@finished and id not in ^failed and
        finished_at <=
          fragment(
            "((now() AT TIME ZONE 'utc') - (? * interval '1 millisecond'))",
            ^retention
          )
    )
    |> Ash.Query.sort(Ash.Sort.expr_sort(fragment("random()"), :float))
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
    |> BulkActionLock.pin()
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      bulk_action -> bulk_action.id
    end
  end

  # A failed delete has aborted the transaction: it rolls back, this bulk
  # action alone, and the prune goes on.
  defp delete(resource, repo, id) do
    table = AshPostgres.DataLayer.Info.table(resource)
    prefix = AshPostgres.DataLayer.Info.schema(resource)

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

      repo.rollback({:failed, id})
  end
end
