defmodule AshBulkDurable.Core.Changes.ApplyMarkFinished do
  @moduledoc """
  Implements the `:mark_finished` update action on `BulkAction`. Reads the
  `result` argument and translates it into the terminal `status`,
  `result`, `error` and `finished_at` attributes.

  Accepted shapes for `result`:

    * `:completed`                     — every row succeeded
    * `:completed_with_errors`          — worker finished, ≥1 row :failed
    * `{:failed, %{error: error, ...}}`  — worker-level failure; `error`
      is kept as `AshBulkDurable.Core.StoredErrors` on `error`, the rest
      in `result`
    * `{:failed, term}`                  — worker-level failure
    * `:cancelled`                       — user abandoned a bulk action

  Any other shape is treated as `:failed` with the raw value stored
  under `result.error`.

  ## Status guard

  The update is filtered on `status in [:queued, :running,
  :completed_with_errors]` — the same set that holds the user's
  one-unresolved slot. A call on an already-terminal bulk action (`:completed`,
  `:failed`, `:cancelled`) is rejected as `StaleRecord` rather than
  silently overwriting the verdict: if one run finishes a bulk action and
  an overlapping run then tries to finalize it, the second UPDATE no-ops.

  ## Eager staging purge on `:cancelled`

  The Abandon path flips a `:completed_with_errors` bulk action to
  `:cancelled` long after the worker exited, so nothing on the bulk action's own
  code path can drop its staged files. For that case this change adds an
  `after_transaction` hook that calls
  `AshBulkDurable.Core.PurgeStaleStaging.delete_staging/1` once the cancel
  has committed. The delete is best-effort and never changes the cancel's
  result:

    * it is skipped when the cancel failed;
    * it is skipped when the bulk action's repo is still in a transaction
      (the cancel ran inside a caller's own transaction, which could still
      roll back);
    * an exception from storage is rescued and logged as a warning.

  In each of those cases the daily sweep reclaims the `:cancelled` bulk
  action's files on its next pass. Other terminal flips (`:completed`,
  `:failed`, `:completed_with_errors`) are handled by the worker's own
  `maybe_delete_staging/1`, so only `:cancelled` deletes here.
  """
  use Ash.Resource.Change
  require Ash.Expr
  require Logger

  alias AshBulkDurable.Core.PurgeStaleStaging

  @impl true
  def change(changeset, _opts, _context) do
    arg = Ash.Changeset.get_argument(changeset, :result)
    {status, result_blob, error} = interpret(arg)

    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status in [:queued, :running, :completed_with_errors]))
    |> Ash.Changeset.force_change_attribute(:status, status)
    |> Ash.Changeset.force_change_attribute(:result, result_blob)
    |> Ash.Changeset.force_change_attribute(:error, error)
    |> Ash.Changeset.force_change_attribute(:finished_at, DateTime.utc_now())
    |> maybe_delete_staging(status)
  end

  defp maybe_delete_staging(changeset, :cancelled) do
    Ash.Changeset.after_transaction(changeset, fn
      changeset, {:ok, bulk_action} = result ->
        repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)
        unless repo.in_transaction?(), do: delete_staging(bulk_action)
        result

      _changeset, result ->
        result
    end)
  end

  defp maybe_delete_staging(changeset, _status), do: changeset

  defp delete_staging(bulk_action) do
    PurgeStaleStaging.delete_staging(bulk_action)
  rescue
    error ->
      Logger.warning(
        "could not delete the staged files of abandoned bulk action #{bulk_action.id}, " <>
          "the daily sweep will: " <> Exception.message(error)
      )
  end

  defp interpret(:completed), do: {:completed, %{outcome: "completed"}, nil}

  defp interpret(:completed_with_errors),
    do: {:completed_with_errors, %{outcome: "completed_with_errors"}, nil}

  defp interpret(:cancelled), do: {:cancelled, %{outcome: "cancelled"}, nil}

  defp interpret({:failed, %{} = details}) when not is_struct(details) do
    {error, details} = Map.pop(details, :error)

    blob =
      details
      |> Map.put_new(:outcome, "failed")
      |> Map.new(fn {k, v} -> {to_string(k), serialize(v)} end)

    {:failed, blob, error}
  end

  defp interpret({:failed, term}) do
    {:failed, %{"outcome" => "failed", "error" => inspect(term)}, nil}
  end

  defp interpret(other) do
    {:failed, %{"outcome" => "failed", "error" => inspect(other)}, nil}
  end

  defp serialize(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp serialize(nil), do: nil
  defp serialize(value) when is_atom(value), do: to_string(value)
  defp serialize(value) when is_list(value), do: Enum.map(value, &serialize/1)

  defp serialize(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), serialize(v)} end)

  defp serialize(value), do: inspect(value)
end
