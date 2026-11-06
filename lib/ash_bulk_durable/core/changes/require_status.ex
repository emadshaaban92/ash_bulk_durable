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
  """
  use Ash.Resource.Change
  require Ash.Expr

  @impl true
  def change(changeset, opts, _context) do
    statuses = Keyword.fetch!(opts, :statuses)
    Ash.Changeset.filter(changeset, Ash.Expr.expr(status in ^statuses))
  end
end
