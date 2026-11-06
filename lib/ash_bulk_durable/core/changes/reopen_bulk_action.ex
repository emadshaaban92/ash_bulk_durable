defmodule AshBulkDurable.Core.Changes.ReopenBulkAction do
  @moduledoc """
  Implements `BulkAction.:enqueue_retry`: a finished bulk action takes its
  corrected shared `input`, when given, and sheds how it finished, the
  liveness hint its last run left included, so a poller starts it at once
  rather than once that hint goes stale. Its crash count starts again
  (`stalled_starts`, `progress_at_start`, `shutdown_stopped` and
  `isolating_row_id`; see "Crashes" in `AshBulkDurable.Core.Worker`). Its
  `pass` goes up by one, so a run that started before the retry stops at its
  next lock instead of carrying on into this pass with the last one's
  settings (see "Passes" in `AshBulkDurable.Core.Worker`).

  Only a bulk action parked in `:completed_with_errors` or `:failed` matches
  the update. One `:queued` or `:running`, or already `:completed` or
  `:cancelled`, is rejected as `StaleRecord`, so a double-fired retry or a
  stale tab cannot reopen rows a run is driving.
  """
  use Ash.Resource.Change
  require Ash.Expr

  alias AshBulkDurable.Core.Runner

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status in [:completed_with_errors, :failed]))
    |> Ash.Changeset.force_change_attribute(:result, nil)
    |> Ash.Changeset.force_change_attribute(:error, nil)
    |> Ash.Changeset.force_change_attribute(:finished_at, nil)
    |> Ash.Changeset.force_change_attribute(:alive_at, nil)
    |> Ash.Changeset.force_change_attribute(:stalled_starts, 0)
    |> Ash.Changeset.force_change_attribute(:progress_at_start, nil)
    |> Ash.Changeset.force_change_attribute(:shutdown_stopped, false)
    |> Ash.Changeset.force_change_attribute(:isolating_row_id, nil)
    |> Ash.Changeset.atomic_update(:pass, Ash.Expr.expr(pass + 1))
    |> put_input()
  end

  defp put_input(changeset) do
    case Ash.Changeset.fetch_argument(changeset, :input) do
      {:ok, input} ->
        Ash.Changeset.force_change_attribute(changeset, :input, Runner.stored_input(input))

      :error ->
        changeset
    end
  end
end
