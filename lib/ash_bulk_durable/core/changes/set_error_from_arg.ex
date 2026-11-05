defmodule AshBulkDurable.Core.Changes.SetErrorFromArg do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :error) do
      nil -> changeset
      value -> Ash.Changeset.force_change_attribute(changeset, :error, value)
    end
  end
end
