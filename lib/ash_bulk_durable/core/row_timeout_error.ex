defmodule AshBulkDurable.Core.RowTimeoutError do
  @moduledoc """
  What fails a row whose references took longer to resolve than
  `:row_resolve_timeout` allows.
  """
  defexception [:timeout]

  @impl true
  def message(%{timeout: timeout}), do: "the row took longer than #{timeout}ms to resolve"
end
