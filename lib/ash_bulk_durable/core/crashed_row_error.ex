defmodule AshBulkDurable.Core.CrashedRowError do
  @moduledoc """
  What fails a row that stopped the worker every time it ran alone: its run
  was killed, ran out of memory or crashed the node, `attempts` times, so it
  is not run again and the rows around it still run (see "Crashes" in
  `AshBulkDurable.Core.Worker`).
  """
  defexception [:attempts]

  @impl true
  def message(%{attempts: attempts}),
    do: "this row stopped the worker #{attempts} times, so it was not run again"
end
