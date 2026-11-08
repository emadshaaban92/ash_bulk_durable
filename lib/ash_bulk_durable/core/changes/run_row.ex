defmodule AshBulkDurable.Core.Changes.RunRow do
  @moduledoc """
  Drives a batch of `Row`s through the `:run` action: for each row it
  performs the target create/update/destroy (`Runner.run_row/2`) and flips the row's
  own status — plus bumps the bulk action's `rows_done` — inside the action's own
  transaction. No manual `Ash.transaction`.

  Only `batch_change/3` (+ `after_batch/3`) is defined, so the one change serves
  both `Ash.update(row, :run)` and `Ash.bulk_update(rows, :run)`; a single row
  is a batch of 1.

  The batch is atomic: if any row errors, Ash rolls the whole batch back (every
  target write, every status flip, the `rows_done` bump). The worker exploits
  that — it runs a chunk as one batch and, on failure, re-runs the rows one at a
  time (each its own batch) so good rows commit and only the bad ones fail.

  In all-or-nothing mode each slice also reports how many rows the open
  transaction has written (`AshBulkDurable.Core.Progress`), since nothing is
  announced until it commits.

  The bulk action's `Runner.Settings` ride in on the action context under
  `:ash_bulk_durable`, so the worker builds them once per bulk action.
  """
  use Ash.Resource.Change

  alias AshBulkDurable.Core.{Progress, Runner, Transient}

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def after_batch([{first_changeset, _} | _] = pairs, _opts, context) do
    %{settings: settings, bulk_action: bulk_action} =
      bulk_action_context(context, first_changeset)

    # Each row is written on its own, so its record id lands on the row in the
    # same transaction and a failure names the row it came from. The chunk's
    # atomicity comes from the worker wrapping this whole `:run` batch in one
    # transaction.
    {results, {succeeded, trouble}} =
      Enum.map_reduce(pairs, {0, nil}, fn
        {changeset, _row}, {succeeded, trouble} when trouble != nil ->
          {{:error, on_row(changeset, trouble)}, {succeeded, trouble}}

        {changeset, row}, {succeeded, nil} ->
          with {:ok, record} <- run_row(settings, row),
               {:ok, row} <- mark_succeeded(row, record) do
            {{:ok, row}, {succeeded + 1, nil}}
          else
            {:error, error} -> {{:error, on_row(changeset, error)}, {succeeded, trouble(error)}}
          end
      end)

    if succeeded > 0 and is_nil(trouble),
      do: bulk_action |> bump_rows_done(succeeded) |> report_progress()

    results
  end

  # The database's own trouble (`Transient`) has aborted the transaction, so
  # nothing after it can run: the rows left fail with it unrun, and the
  # worker raises it, leaving them all for the next start.
  defp trouble(error), do: if(Transient.transient?(error), do: error)

  # A raise fails its row like any other error, so the rows around it still
  # run: every attempt would hit it again, and take them down with it.
  defp run_row(settings, row) do
    Runner.run_row(settings, row)
  rescue
    exception -> Runner.row_raised(exception, __STACKTRACE__, row)
  end

  # A target that can't be read fails with no changeset of its own, so the
  # row's is what ties the error to its row.
  defp on_row(changeset, error), do: Ash.Changeset.add_error(changeset, error)

  # The flip is a compare-and-set (`RequireStatus`): a row another run
  # already wrote refuses it, and that refusal fails the row like a target
  # error, so the batch rolls back and the worker can tell it apart.
  defp mark_succeeded(row, record) do
    row
    |> Ash.Changeset.for_update(:mark_succeeded, %{record_id: record_id(record)},
      authorize?: false
    )
    |> Ash.update(authorize?: false)
  end

  # Query-encoded, so a part holding a separator can't run into the next one.
  defp record_id(%resource{} = record) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] -> record |> Map.fetch!(key) |> to_string()
      keys -> record |> Map.take(keys) |> URI.encode_query()
    end
  end

  defp bump_rows_done(bulk_action, n) do
    bulk_action
    |> Ash.Changeset.for_update(:bump_rows_done, %{n: n}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  # An all-or-nothing run is one transaction, so the bump above is announced
  # only when it commits. Until then a page is told how far the slices have
  # got, as a hint (`Progress`). The bump is atomic, so the bulk action it
  # returns counts every row this transaction has written so far.
  defp report_progress(%{mode: :all_or_nothing} = bumped),
    do: Progress.writing(bumped, bumped.rows_done)

  defp report_progress(_bumped), do: :ok

  # The worker passes the settings and bulk action via the action's `context:`. Ash
  # exposes it on the callback context and on each changeset's context; read
  # whichever carries it.
  defp bulk_action_context(%{ash_bulk_durable: data}, _changeset), do: data
  defp bulk_action_context(_context, %{context: %{ash_bulk_durable: data}}), do: data
end
