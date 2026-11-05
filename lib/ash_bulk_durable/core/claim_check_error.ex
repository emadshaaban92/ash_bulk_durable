defmodule AshBulkDurable.Core.ClaimCheckError do
  @moduledoc """
  A row write couldn't confirm its run's claim because the database failed
  (`AshBulkDurable.Core.Lease.confirm_claim/2`). It says nothing about the
  row or the claim, so the worker never stores it as a row's error: it
  raises it, and the attempt is given up and claimed again after a backoff.
  """
  use Splode.Error, fields: [:bulk_action_id, :error], class: :unknown

  def message(%{bulk_action_id: id, error: error}) do
    "couldn't confirm the claim on bulk action #{id}: " <> describe(error)
  end

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error)
end
