defmodule AshBulkDurable.Core.Changes.ReopenBulkAction do
  @moduledoc """
  Implements `BulkAction.:enqueue_retry`: a finished bulk action takes its
  corrected shared `input`, when given, sheds how it finished, and goes back
  to `:queued` with no claim and a fresh attempt count, for the next poll to
  claim.

  Only a bulk action parked in `:completed_with_errors` or `:failed` matches
  the update. One `:queued` or `:running`, or already `:completed` or
  `:cancelled`, is rejected as `StaleRecord`, so a double-fired retry or a
  stale tab cannot start a second run over the same rows.
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
    |> Ash.Changeset.force_change_attribute(:status, :queued)
    |> Ash.Changeset.force_change_attribute(:started_at, nil)
    |> Ash.Changeset.force_change_attribute(:lease_until, nil)
    |> Ash.Changeset.force_change_attribute(:claim_token, nil)
    |> Ash.Changeset.force_change_attribute(:attempts, 0)
    |> Ash.Changeset.force_change_attribute(:shutdowns, 0)
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
