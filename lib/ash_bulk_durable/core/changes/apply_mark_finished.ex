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
  silently overwriting the verdict. The worker also fences its calls on its
  claim token (`AshBulkDurable.Core.Lease.fenced/2`), so a run that lost its
  claim cannot finalize over the run that took it over.

  ## Eager staging purge on `:cancelled`

  The Abandon path flips a `:completed_with_errors` bulk action to
  `:cancelled` long after the worker exited, so nothing on the bulk action's
  own code path can drop its staged files. This change deletes them once the
  cancel commits (`AshBulkDurable.Core.PurgeStaleStaging.delete_staging/1`).
  A cancel made inside a caller's own transaction hasn't committed when its
  own action ends, and could still roll back: its files are left for the
  sweep instead. It is best-effort — a failed delete never fails the cancel, because the
  staging sweep catches the `:cancelled` bulk action on its next pass. Other
  terminal flips (`:completed`, `:failed`, `:completed_with_errors`) are
  handled by the worker's own `maybe_delete_staging/1`, so only `:cancelled`
  purges here.
  """
  use Ash.Resource.Change
  require Ash.Expr
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    arg = Ash.Changeset.get_argument(changeset, :result)
    {status, result_blob, error} = interpret(arg)

    changeset
    |> Ash.Changeset.filter(Ash.Expr.expr(status in [:queued, :running, :completed_with_errors]))
    |> Ash.Changeset.force_change_attribute(:status, status)
    |> Ash.Changeset.force_change_attribute(:result, result_blob)
    |> Ash.Changeset.force_change_attribute(:error, error)
    # The database's clock, the one `started_at` is stamped with.
    |> Ash.Changeset.atomic_update(
      :finished_at,
      Ash.Expr.expr(fragment("(now() AT TIME ZONE 'utc')"))
    )
    |> maybe_purge_staging(status)
  end

  defp maybe_purge_staging(changeset, :cancelled) do
    Ash.Changeset.after_transaction(changeset, fn
      changeset, {:ok, bulk_action} ->
        unless in_outer_transaction?(changeset), do: purge_staging(bulk_action)
        {:ok, bulk_action}

      _changeset, error ->
        error
    end)
  end

  defp maybe_purge_staging(changeset, _status), do: changeset

  defp in_outer_transaction?(changeset),
    do: AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate).in_transaction?()

  defp purge_staging(bulk_action) do
    AshBulkDurable.Core.PurgeStaleStaging.delete_staging(bulk_action)
  rescue
    exception ->
      Logger.warning(
        "bulk action #{bulk_action.id} kept its staged files: #{Exception.message(exception)}"
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
