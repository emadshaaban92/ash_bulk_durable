defmodule AshBulkDurable.Core.Changes.RequireStatus do
  @moduledoc """
  Makes a row's status flip a compare-and-set: the update matches the row
  only while its status is one of `statuses`, and is refused as
  `Ash.Error.Changes.StaleRecord` otherwise.

  Two runs of one bulk action can overlap: two pollers starting it at once,
  or one started again while the first, still alive, had not stamped its
  liveness hint in time. The guard keeps the later writer from applying a row twice, or from
  moving one back after it succeeded; the target writes sharing the refused
  flip's transaction roll back with it. The worker reads such a refusal as
  its row having moved on under another run, and stops.

  ## The run's pass

  A run's phase-1 writes (`:resolve`, and `:mark_failed` there) take no lock,
  so the status alone can't tell them that a retry reopened their row since
  the run started: back at `:pending`, the row matches again. Such a write
  carries its run's `pass` in the action context, under
  `ash_bulk_durable: %{pass: pass}`, and the guard then also matches the row
  only while the row's own `pass` is that one. `AshBulkDurable.Core.Retry`
  writes the next pass onto every row it reopens, in the transaction that
  moves the bulk action on to it, so the stale run's write is refused the
  same way, and the run stops. A write without a pass in its context (a
  host's own call, `AshBulkDurable.Core.Retry`'s, the worker's writes under
  the lock, which filters on the pass itself) is matched on its status alone.

  The pass is the row's own column, not the bulk action's read through a
  subquery: a write that waited on the row while a retry held it rechecks
  only the row's new version once the retry commits, and a subquery on the
  bulk action would still see the pass as it was when the write started.
  """
  use Ash.Resource.Change
  require Ash.Expr

  @impl true
  def change(changeset, opts, _context) do
    statuses = Keyword.fetch!(opts, :statuses)

    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status in ^statuses))
    |> require_pass()
  end

  defp require_pass(%{context: %{ash_bulk_durable: %{pass: pass}}} = changeset)
       when is_integer(pass),
       do: Ash.Changeset.filter(changeset, Ash.Expr.expr(pass == ^pass))

  defp require_pass(changeset), do: changeset
end
