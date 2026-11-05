defmodule AshBulkDurable.Core.Changes.RequireStatus do
  @moduledoc """
  Makes a row's status flip a compare-and-set: the update matches only a row
  still in one of `statuses`, and is rejected as `StaleRecord` otherwise.

  A run whose claim another run took over may still hold rows it read
  before; the run that took over has written them since, so the stale run's
  flips match nothing, and the target writes sharing their transaction roll
  back with them. The worker reads such a rejection as its claim lost.
  """
  use Ash.Resource.Change
  require Ash.Expr

  @impl true
  def change(changeset, opts, _context) do
    statuses = Keyword.fetch!(opts, :statuses)
    Ash.Changeset.filter(changeset, Ash.Expr.expr(status in ^statuses))
  end
end
