defmodule AshBulkDurable.Core.Changes.ValidateMaxRows do
  @moduledoc """
  `validate`-stage check on `BulkAction.:create` that refuses a bulk action
  of more rows than `:max_rows` (default `100_000`), in either mode, before
  any row is written: its rows are held in memory while they are written,
  so a larger one is split by its caller. The single source of truth for the
  cap; `AshBulkDurable.Core.create/4` reads no more of a stream than it
  takes to go over it.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    total_rows = Ash.Changeset.get_attribute(changeset, :total_rows)
    cap = AshBulkDurable.Core.max_rows()

    if is_integer(total_rows) and total_rows > cap do
      {:error,
       field: :total_rows,
       message: "a bulk action is capped at #{cap} rows; split it into smaller ones."}
    else
      :ok
    end
  end
end
