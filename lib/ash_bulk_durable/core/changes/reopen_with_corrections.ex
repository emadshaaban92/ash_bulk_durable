defmodule AshBulkDurable.Core.Changes.ReopenWithCorrections do
  @moduledoc """
  Implements the `:reopen_with_corrections` action on `Row`: a row that has
  not succeeded takes its corrected `target`, `input` and `metadata` (each
  kept as it was when not given) and goes back to the worker. `shared_input`
  is the input the bulk action will hold once retried, when that changes.

  A row that succeeded matches no row of the update, whatever the caller
  read: it is rejected as `StaleRecord`, as running it twice would count it
  twice and the bulk action could never complete.

  What the resolve phase resolved is kept only where the reference behind
  it is unchanged, between the inputs the row ran and will run with, either
  of which may be the bulk action's: an input whose corrected value differs
  is resolved again, and so is a tenant reference the corrected target
  changed. Untouched ones
  (e.g. a photo whose reference names the same file) keep their resolved
  value, so the resolve phase reruns only what genuinely needs redoing.

  The row returns to `:pending` while it holds a reference, `:resolved`
  otherwise, its `attempts` back to 0, so runs that died on it before the
  correction count no more; a correction its caller already refused (`error`) leaves it
  `:failed` and `refused` with that error.
  """
  use Ash.Resource.Change

  require Ash.Expr

  alias AshBulkDurable.Core.Runner

  @impl true
  def change(changeset, _opts, _context) do
    row = changeset.data
    ran_with = shared_input(row)

    will_run_with =
      case Ash.Changeset.fetch_argument(changeset, :shared_input) do
        {:ok, shared_input} -> shared_input
        :error -> ran_with
      end

    corrected = %{
      target: argument(changeset, :target, row.target),
      input: changeset |> argument(:input, row.input) |> Runner.stored_input(),
      metadata: argument(changeset, :metadata, row.metadata),
      error: Ash.Changeset.get_argument(changeset, :error)
    }

    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status != :succeeded))
    |> Ash.Changeset.force_change_attribute(:target, corrected.target)
    |> Ash.Changeset.force_change_attribute(:input, corrected.input)
    |> Ash.Changeset.force_change_attribute(:metadata, corrected.metadata)
    |> Ash.Changeset.force_change_attribute(:error, corrected.error)
    |> Ash.Changeset.force_change_attribute(:refused, not is_nil(corrected.error))
    |> Ash.Changeset.force_change_attribute(:attempts, 0)
    |> Ash.Changeset.force_change_attribute(
      :resolved_data,
      kept_resolutions(row, corrected, ran_with, will_run_with)
    )
    |> Ash.Changeset.force_change_attribute(
      :resolved_tenant,
      kept_tenant(row, corrected.target)
    )
    |> Ash.Changeset.force_change_attribute(
      :status,
      Runner.initial_status(corrected, will_run_with)
    )
  end

  defp shared_input(row),
    do: Ash.load!(row, :bulk_action, lazy?: true, authorize?: false).bulk_action.input

  defp argument(changeset, name, current) do
    case Ash.Changeset.fetch_argument(changeset, name) do
      {:ok, value} when not is_nil(value) -> value
      _missing -> current
    end
  end

  # A lookup finds a record only in its tenant, so none outlives a change of it.
  defp kept_resolutions(row, corrected, ran_with, will_run_with) do
    if tenant_of(row.target) == tenant_of(corrected.target) do
      old = row |> Runner.input(ran_with) |> by_name()
      new = corrected |> Runner.input(will_run_with) |> by_name()

      Map.filter(row.resolved_data || %{}, fn {name, _resolved} ->
        Map.fetch(old, name) == Map.fetch(new, name)
      end)
    else
      %{}
    end
  end

  defp by_name(input), do: Map.new(input, fn {key, value} -> {to_string(key), value} end)

  defp kept_tenant(row, target) do
    if tenant_of(row.target) == tenant_of(target), do: row.resolved_tenant
  end

  defp tenant_of(%{tenant: tenant}), do: tenant
  defp tenant_of(_target), do: nil
end
