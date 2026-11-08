defmodule AshBulkDurable.Core.RowExitError do
  @moduledoc """
  What fails a row whose resolution threw or exited instead of returning or
  raising: a `throw/1`, an `exit/1`, or the task resolving it dying. `kind`
  is `:throw` or `:exit`; `reason` is the thrown value or exit reason as
  text, so the row keeps what happened but no live term.
  """
  defexception [:kind, :reason]

  @doc "The error for a `kind` and `reason` caught while resolving a row."
  def new(kind, reason) when kind in [:throw, :exit] do
    %__MODULE__{kind: kind, reason: describe(kind, reason)}
  end

  @impl true
  def message(%{kind: :throw, reason: reason}), do: "resolving the row threw: #{reason}"
  def message(%{kind: :exit, reason: reason}), do: "resolving the row exited: #{reason}"

  defp describe(:throw, value), do: inspect(value, limit: 20, printable_limit: 200)
  defp describe(:exit, reason), do: Exception.format_exit(reason)
end
