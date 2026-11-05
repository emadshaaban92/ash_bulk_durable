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
  silently overwriting the verdict. This closes the worker-vs-rescue
  race: if the rescue cron flips a stuck `:running` bulk action to
  `:failed`/`worker_lost` and a delayed worker then tries to finalize
  `:completed`, the worker's UPDATE no-ops.

  ## Eager staging purge on `:cancelled`

  The Abandon path flips a `:completed_with_errors` bulk action to
  `:cancelled` long after the worker exited, so nothing on the bulk action's own
  code path can drop its staged files. This change enqueues a
  one-shot `AshBulkDurable.Core.PurgeStaleStaging` job for that case. The enqueue
  is best-effort — a failed insert never blocks the cancel, because the
  daily sweep catches the `:cancelled` bulk action on its next pass. Other
  terminal flips (`:completed`, `:failed`, `:completed_with_errors`) are
  handled by the worker's own `maybe_delete_staging/1`, so only
  `:cancelled` enqueues here.
  """
  use Ash.Resource.Change
  require Ash.Expr

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
    |> maybe_enqueue_staging_purge(status)
  end

  defp maybe_enqueue_staging_purge(changeset, :cancelled) do
    Ash.Changeset.after_action(changeset, fn _changeset, bulk_action ->
      _ =
        Oban.insert(
          AshBulkDurable.Core.oban(),
          AshBulkDurable.Core.PurgeStaleStaging.new(%{bulk_action_id: bulk_action.id})
        )

      {:ok, bulk_action}
    end)
  end

  defp maybe_enqueue_staging_purge(changeset, _status), do: changeset

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
