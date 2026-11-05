defmodule AshBulkDurable.Core.Changes.RequireClaim do
  @moduledoc """
  Fences a single row write on the worker's claim: when the write carries the
  claim it runs under (`context.ash_bulk_durable.claim`, an `%{id, token}`),
  it confirms the token still holds the bulk action, inside the write's own
  transaction, before it commits (`AshBulkDurable.Core.Lease.confirm_claim/2`).
  A write made by anything other than a run carries no claim and is left
  alone.

  A claim already taken over fails the write as a row whose status moved on
  would (`Ash.Error.Changes.StaleRecord`), so the worker stops the run the
  same way. A batch of rows under `:run` is fenced once for the whole batch
  instead (`AshBulkDurable.Core.Changes.RunRow`). A database error checking
  it fails the write with `AshBulkDurable.Core.ClaimCheckError`, which the
  worker raises rather than storing on the row.
  """
  use Ash.Resource.Change

  alias AshBulkDurable.Core.Lease

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.context do
      %{ash_bulk_durable: %{claim: %{id: id, token: token}}} ->
        Ash.Changeset.before_action(changeset, &confirm(&1, id, token))

      _no_claim ->
        changeset
    end
  end

  defp confirm(changeset, id, token) do
    case Lease.confirm_claim(id, token) do
      :ok ->
        changeset

      :lost ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.StaleRecord.exception(
            resource: changeset.resource,
            filter: %{id: changeset.data.id}
          )
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end
end
