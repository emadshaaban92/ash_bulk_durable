defmodule AshBulkDurable.Core.Changes.ValidateAtomicModeLimit do
  @moduledoc """
  `validate`-stage check on `BulkAction.:create` that refuses an
  `:all_or_nothing` bulk action of more rows than `:atomic_mode_max_rows`
  (default `10_000`): one transaction over more rows than that must run
  `:per_row` instead. The single source of truth for the cap; the worker
  does not check it again.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    mode = Ash.Changeset.get_attribute(changeset, :mode)
    total_rows = Ash.Changeset.get_attribute(changeset, :total_rows)
    cap = AshBulkDurable.Core.config(:atomic_mode_max_rows, 10_000)

    if mode == :all_or_nothing and is_integer(total_rows) and total_rows > cap do
      {:error,
       field: :mode,
       message:
         "an all-or-nothing bulk action is capped at #{cap} rows; " <>
           "got #{total_rows}. Run it per row."}
    else
      :ok
    end
  end
end
