defmodule AshBulkDurable.Core.Retry do
  @moduledoc """
  Puts a finished bulk action's rows back to the worker: `retry/2` every row
  that has not succeeded, `retry_row/2` one failed row alone. Both write the
  corrections and queue the bulk action again in one transaction, and the
  worker then runs the rows that are no longer finished, as it ran them the
  first time. Once that transaction returns, this node's poller is nudged to
  start it (`AshBulkDurable.Core.Poller.nudge/0`), unless the call ran inside
  a transaction of the caller's, when the next poll starts it.

  A retry first locks the bulk action (`AshBulkDurable.Core.BulkActionLock`),
  before any of its rows, and reads the rows and the bulk action's state under
  that lock, not from the caller's copy. A bulk action that finished with
  failed rows, or failed outright, can be retried. One queued or running is
  refused, as are one completed or cancelled and one the caller's scope does
  not own, and one whose lock another transaction holds, such as a run's: that
  retry is refused at once rather than waiting for it. A caller who does not
  own it never locks it, so learns nothing of its rows. Two retries cannot
  race: the second finds the lock held or the status moved on. An owner has
  one unresolved bulk action at a time, queued, running or parked in
  `:completed_with_errors` (the `:one_unresolved_per_user` identity). A
  failed one has given that slot up and a retry takes it back, so while its
  owner has another unresolved one the retry is refused with `{:error,
  %{unresolved: id}}`, that one's id, nothing written. A retried bulk action
  is `:queued` again, and its run takes it to `:running`. One whose
  resource or action no longer exists, or that stored what no longer decodes
  (`AshBulkDurable.Core.StoredTerm`), returns `{:error, :gone}` to its owner,
  who can only abandon it.

  A row its caller refused before it was stored never ran and has no input
  to run as it is: only a correction reopens it.
  """

  import Ash.Expr, only: [expr: 1]

  require Ash.Expr
  require Ash.Query

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.{BulkActionLock, Introspection, Owner, Poller, Runner}

  @doc """
  Reruns every row of `bulk_action` that has not succeeded. Returns `{:ok,
  bulk_action}`, the bulk action `:queued`; `{:error, %{unmatched: ids}}`
  with nothing written when `:rows` names a row that is not one of them;
  `{:error, %{unresolved: id}}` with nothing written when it failed and its
  owner has another unresolved bulk action since, `id`; or `{:error,
  error}` when refused.

  Options:

    * `:scope` (required) — must be the bulk action's owner.
    * `:input` — replaces the shared input; a row with its own keeps it.
    * `:rows` — `%{row_id => correction}`, a correction being any of
      `:input` (the row's own), `:lookup` (the keys of its target to change,
      for a row found by an identity), `:tenant` (a value or a lookup, the
      tenant it acts in instead), `:metadata`, and `:error`, a refusal that
      keeps the row failed.

  Raises `ArgumentError` for a `:lookup` or `:tenant` on a row whose target
  is a record selected by its primary key, which stays the record selected.
  """
  def retry(bulk_action, opts) do
    corrections = opts |> Keyword.get(:rows, %{}) |> Map.new()
    shared = opts |> Keyword.take([:input]) |> Map.new()

    reopen(bulk_action, corrections, shared, opts, &{:ok, open_rows(&1)})
  end

  @doc """
  Reruns one failed `row` alone, the bulk action's other rows staying as
  they are, through the same run: its result is read as `retry/2`'s is.

  The run runs every row left unprocessed, so a bulk action that failed
  before reaching them is refused with `{:error, %{unprocessed: count}}`,
  nothing written: `retry/2` resumes them.

  Takes `:scope`, and `:input`, `:lookup`, `:tenant` and `:metadata` as a correction in
  `retry/2`'s `:rows`. Returns as `retry/2`, a row no longer failed being
  unmatched. An all-or-nothing bulk action has no row by itself: raises
  `ArgumentError`.
  """
  def retry_row(row, opts) do
    %{bulk_action: bulk_action} = Ash.load!(row, :bulk_action, authorize?: false)

    if bulk_action.mode == :all_or_nothing,
      do: raise(ArgumentError, "an all-or-nothing bulk action retries whole, not by row")

    correction = opts |> Keyword.take([:input, :lookup, :tenant, :metadata]) |> Map.new()

    reopen(bulk_action, %{row.id => correction}, %{}, opts, fn locked ->
      with :ok <- nothing_unprocessed(locked), do: {:ok, failed(row)}
    end)
  end

  @doc "The rows of `bulk_action` that have not succeeded, in the order they run."
  def open_rows(bulk_action) do
    Core.config(:row_resource)
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status != :succeeded)
    |> Ash.Query.sort(row_index: :asc)
    |> BulkActionLock.pin()
    |> Ash.read!(authorize?: false)
  end

  defp failed(row) do
    Core.config(:row_resource)
    |> Ash.Query.filter(id == ^row.id)
    |> BulkActionLock.pin()
    |> Ash.read_one!(authorize?: false)
    |> case do
      %{status: :failed} = fresh -> [fresh]
      _finished -> []
    end
  end

  # Only a failed bulk action can have stopped short: every other retryable
  # one ran all its rows. Given the locked bulk action, so its status is the
  # committed one.
  defp nothing_unprocessed(%{status: :failed} = bulk_action) do
    Core.config(:row_resource)
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status in [:pending, :resolved])
    |> BulkActionLock.pin()
    |> Ash.count!(authorize?: false)
    |> case do
      0 -> :ok
      count -> {:error, %{unprocessed: count}}
    end
  end

  defp nothing_unprocessed(_bulk_action), do: :ok

  @retryable [:completed_with_errors, :failed]

  # The bulk action is locked before anything reads or writes its rows (see
  # `AshBulkDurable.Core.BulkActionLock`), and what it holds is read under the
  # lock rather than taken from the caller, whose copy may predate another
  # retry. A refusal before the first write is returned as it is, nothing
  # written; `Ash.transaction` would turn a rollback's `%{unmatched: ids}`
  # into an unknown error.
  defp reopen(bulk_action, corrections, shared, opts, rows) do
    resources = [Core.config(:bulk_action_resource), Core.config(:row_resource)]

    with {:ok, result} <-
           Ash.transaction(resources, fn ->
             under_lock(resources, bulk_action, corrections, shared, opts, rows)
           end) do
      Poller.nudge_after(result)
    end
  end

  defp under_lock(resources, bulk_action, corrections, shared, opts, rows) do
    with {:ok, locked} <- lock(bulk_action, opts),
         :ok <- Introspection.runnable(locked),
         :ok <- slot_free(locked),
         {:ok, rows} <- rows.(locked),
         :ok <- Introspection.readable(rows),
         :ok <- all_known(corrections, rows) do
      write(resources, rows, corrections, shared, locked, opts)
    end
  end

  # Each row compares the shared input it ran with to the one it will, so the
  # rows reopen before `:enqueue_retry` moves that input on. The rows and the
  # bulk action take one pass, read under the lock: a run of an earlier pass
  # finds every reopened row on another pass, its phase-1 writes included.
  defp write(resources, rows, corrections, shared, locked, opts) do
    pass = locked.pass + 1

    with :ok <- reopen_rows(rows, corrections, shared, locked, pass),
         {:ok, retried} <- enqueue(locked, Map.put(shared, :pass, pass), opts) do
      {:ok, retried}
    else
      {:error, error} -> Ash.DataLayer.rollback(resources, error)
    end
  end

  # Only the owner's: anyone else is refused before reading anything, as
  # `:enqueue_retry` refuses a bulk action it matches no row of.
  defp lock(bulk_action, opts) do
    owner = Owner.worker_key(Keyword.fetch!(opts, :scope))

    case BulkActionLock.lock(bulk_action.id, @retryable, filter: expr(user_id == ^owner)) do
      {:ok, locked} ->
        {:ok, locked}

      :none ->
        resource = Core.config(:bulk_action_resource)

        {:error,
         Ash.Error.to_error_class(
           Ash.Error.Changes.StaleRecord.exception(
             resource: resource,
             filter: %{id: bulk_action.id, status: @retryable, user_id: owner}
           )
         )}
    end
  end

  # A `:failed` bulk action is out of its owner's one unresolved slot (the
  # `:one_unresolved_per_user` identity), which `:enqueue_retry` puts it back
  # in: read under the lock, before any row is written, which one holds it
  # now, if any, through the same status set as the identity's. One parked in
  # `:completed_with_errors` holds the slot itself. A bulk action submitted in
  # the instant between this read and the update is still refused, by the
  # identity, as an `Ash.Error.Invalid`.
  defp slot_free(%{status: :failed} = bulk_action) do
    Core.config(:bulk_action_resource)
    |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: bulk_action.user_id},
      authorize?: false
    )
    |> BulkActionLock.pin()
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> :ok
      holder -> {:error, %{unresolved: holder.id}}
    end
  end

  defp slot_free(_bulk_action), do: :ok

  defp all_known(corrections, rows) do
    case Map.keys(corrections) -- Enum.map(rows, & &1.id) do
      [] -> :ok
      unmatched -> {:error, %{unmatched: unmatched}}
    end
  end

  defp reopen_rows(rows, corrections, shared, bulk_action, pass) do
    resource = Introspection.resource(bulk_action)

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      correction = Map.get(corrections, row.id, %{})

      case reopen_row(%{row | bulk_action: bulk_action}, correction, shared, resource, pass) do
        {:ok, _row} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp reopen_row(%{refused: true} = row, correction, _shared, _resource, _pass)
       when map_size(correction) == 0,
       do: {:ok, row}

  defp reopen_row(row, correction, shared, resource, pass) do
    arguments =
      correction
      |> Map.take([:input, :metadata, :error])
      |> put_target(row, correction, resource)
      |> put_shared_input(shared)
      |> Map.put(:pass, pass)

    Ash.update(row, arguments, action: :reopen_with_corrections, authorize?: false)
  end

  defp put_target(arguments, row, correction, resource) do
    case corrected_target(row, correction, resource) do
      target when target == row.target -> arguments
      target -> Map.put(arguments, :target, target)
    end
  end

  defp corrected_target(row, correction, resource) do
    row.target
    |> corrected_lookup(row, correction, resource)
    |> corrected_tenant(row, correction, resource)
  end

  defp corrected_lookup(target, row, %{lookup: lookup}, resource) do
    unless Runner.found_by_identity?(target, resource) do
      raise ArgumentError, "row #{row.id} has no lookup to correct: its record stays the same"
    end

    Map.update!(target, :lookup, &Map.merge(&1, lookup))
  end

  defp corrected_lookup(target, _row, _correction, _resource), do: target

  defp corrected_tenant(%{lookup: _} = target, row, %{tenant: tenant}, resource) do
    unless Runner.found_by_identity?(target, resource) do
      raise ArgumentError, "row #{row.id} has no tenant to correct: its record stays the same"
    end

    Map.put(target, :tenant, tenant)
  end

  defp corrected_tenant(target, _row, %{tenant: tenant}, _resource),
    do: Map.put(target || %{}, :tenant, tenant)

  defp corrected_tenant(target, _row, _correction, _resource), do: target

  defp put_shared_input(arguments, %{input: input}),
    do: Map.put(arguments, :shared_input, Runner.stored_input(input))

  defp put_shared_input(arguments, _shared), do: arguments

  defp enqueue(bulk_action, shared, opts) do
    owner = Owner.worker_key(Keyword.fetch!(opts, :scope))

    bulk_action
    |> Ash.Changeset.for_update(:enqueue_retry, shared, authorize?: false)
    |> Ash.Changeset.filter(expr(user_id == ^owner))
    |> Ash.update(authorize?: false)
  end
end
