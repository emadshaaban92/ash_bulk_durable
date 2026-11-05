defmodule AshBulkDurable.Core.StagedFileError do
  @moduledoc """
  What fails a row left for a resolver when the bulk action's staged files
  can't be read: the engine can't tell which file a resolver reads, so every
  such row fails, and the rows around them still run.
  """
  defexception []

  @impl true
  def message(_error), do: "a file staged for this bulk action could not be read"
end
