defmodule AshBulkDurable.Core.Worker.RowMovedOnError do
  @moduledoc """
  Raised inside a run when one of its row status flips was refused: the row
  had moved on, written by another run of the same bulk action. The run stops
  there, without writing anything more; `AshBulkDurable.Core.Worker.perform/1`
  rescues it.
  """
  defexception [:bulk_action_id]

  @impl true
  def message(%{bulk_action_id: id}),
    do: "a row of bulk action #{id} moved on under another run"
end
