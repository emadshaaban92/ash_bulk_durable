defmodule AshBulkDurable.Core.Changes.SetRecordIdFromArg do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :record_id) do
      nil -> changeset
      value -> Ash.Changeset.force_change_attribute(changeset, :record_id, value)
    end
  end
end
