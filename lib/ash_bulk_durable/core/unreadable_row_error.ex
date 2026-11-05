defmodule AshBulkDurable.Core.UnreadableRowError do
  @moduledoc """
  What fails a row that was waiting to run when a deploy took away what it
  stored (`AshBulkDurable.Core.StoredTerm`). Running it with what is left could
  write something else, so it does not run.
  """
  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "what this row stored no longer exists"
end
