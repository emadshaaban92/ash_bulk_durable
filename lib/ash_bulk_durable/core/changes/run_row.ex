defmodule AshBulkDurable.Core.Changes.RunRow do
  @moduledoc """
  Drives a batch of `Row`s through the `:run` action: for each row it
  performs the target create/update/destroy (`Runner.run_row/2`) and flips the row's
  own status inside the action's own transaction. No manual `Ash.transaction`.
  Nothing here writes the bulk action's row, so a chunk's transaction never
  locks it and its lease renews while the chunk runs.

  Only `batch_change/3` (+ `after_batch/3`) is defined, so the one change serves
  both `Ash.update(row, :run)` and `Ash.bulk_update(rows, :run)`; a single row
  is a batch of 1.

  The batch is atomic: if any row errors, Ash rolls the whole batch back (every
  target write, every status flip). The worker exploits
  that — it runs a chunk as one batch and, on failure, re-runs the rows one at a
  time (each its own batch) so good rows commit and only the bad ones fail.

  The bulk action's `Runner.Settings` ride in on the action context under
  `:ash_bulk_durable`, so the worker builds them once per bulk action.

  ## Fenced on the claim

  Each row's flip is a compare-and-set on its status, which stops a row being
  applied twice but not a run that lost its claim applying one with what it
  read before (a row forgotten and resolved again, an input corrected on
  retry). So once the last slice of the batch has run, still inside its
  transaction, the run confirms its claim token holds
  (`AshBulkDurable.Core.Lease.confirm_claim/2`). The `FOR SHARE` lock that
  takes is held only from there to the commit, so a renewal waits a moment,
  not the whole transaction, and a claim (`FOR UPDATE SKIP LOCKED`) skips
  the bulk action until a poll after the commit. A claim already taken
  fails every row, which rolls the batch back and stops the run. A database
  error confirming it raises, as one in the batch's own writes would.
  """
  use Ash.Resource.Change

  alias AshBulkDurable.Core.{Lease, Progress, Runner}

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def after_batch([{first_changeset, _} | _] = pairs, _opts, context) do
    %{settings: settings, bulk_action: bulk_action} =
      data = bulk_action_context(context, first_changeset)

    # Each row is written on its own, so its record id lands on the row in the
    # same transaction and a failure names the row it came from. The chunk's
    # atomicity comes from the worker wrapping this whole `:run` batch in one
    # transaction.
    results =
      Enum.map(pairs, fn {changeset, row} ->
        with {:ok, record} <- run_row(settings, row),
             {:ok, succeeded} <- mark_succeeded(row, record) do
          {:ok, succeeded}
        else
          {:error, error} -> {:error, on_row(changeset, error)}
        end
      end)

    done = processed(bulk_action, data, length(pairs))
    confirm_claim(results, data, done)
  end

  # Only once the batch's last slice ran, and only if every row did: a
  # failed row rolls the batch back anyway.
  defp confirm_claim(results, %{rows: rows, claim: %{id: id, token: token}}, rows) do
    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: confirmed(results, Lease.confirm_claim(id, token)),
      else: results
  end

  defp confirm_claim(results, _data, _done), do: results

  defp confirmed(results, :ok), do: results

  defp confirmed(results, :lost),
    do: Enum.map(results, fn {:ok, row} -> {:error, claim_lost(row)} end)

  # Says nothing about the rows: the attempt is given up, to resume later.
  defp confirmed(_results, {:error, error}), do: raise(error)

  # The error a refused row flip gives, so the worker tells it the same way.
  defp claim_lost(%resource{} = row) do
    Ash.Error.Changes.StaleRecord.exception(resource: resource, filter: %{id: row.id})
  end

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

  # A compare-and-set on `:resolved`: a row another run already wrote fails
  # here, which rolls back this row's target write with the batch, and tells
  # the worker its claim was lost.
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

  # Ash hands a streamed batch over in slices (100 rows by default), so an
  # all-or-nothing run's one transaction says how far it got after each: a
  # hint for a page, none of it saved until the transaction commits.
  # Returns how many of the batch's rows have run so far.
  defp processed(bulk_action, %{processed: counter}, n) do
    :counters.add(counter, 1, n)
    done = :counters.get(counter, 1)
    if bulk_action.mode == :all_or_nothing, do: Progress.uncommitted(bulk_action, done)
    done
  end

  # Run outside the worker, with no counter: nothing to count or fence.
  defp processed(_bulk_action, _data, n), do: n

  # The worker passes the settings and bulk action via the action's `context:`. Ash
  # exposes it on the callback context and on each changeset's context; read
  # whichever carries it.
  defp bulk_action_context(%{ash_bulk_durable: data}, _changeset), do: data
  defp bulk_action_context(_context, %{context: %{ash_bulk_durable: data}}), do: data
end
