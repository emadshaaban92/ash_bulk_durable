defmodule AshBulkDurable.Core.Changes.ForgetResolutions do
  @moduledoc """
  Drops the `names` the worker found can no longer be used from
  `Row.resolved_data` and puts the row back to `:pending`, so the resolve
  phase resolves them again.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    names = Ash.Changeset.get_argument(changeset, :names)
    kept = Map.drop(changeset.data.resolved_data, names)

    changeset
    |> Ash.Changeset.force_change_attribute(:resolved_data, kept)
    |> Ash.Changeset.force_change_attribute(:status, :pending)
  end
end
