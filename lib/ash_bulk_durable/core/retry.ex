defmodule AshBulkDurable.Core.Retry do
  @moduledoc """
  Puts a finished bulk action's rows back to the worker: `retry/2` every row
  that has not succeeded, `retry_row/2` one failed row alone. Both write the
  corrections and put the bulk action back to `:queued` in one transaction,
  and the worker then runs the rows that are no longer finished, as it ran
  them the first time.

  A bulk action that finished with failed rows, or failed outright, can be
  retried. One queued or running is refused, as are one completed or
  cancelled and one the caller's scope does not own: the refusal is the
  `:enqueue_retry` update matching no row, so two retries cannot race. One
  whose resource or action no longer exists, or that stored what no longer
  decodes (`AshBulkDurable.Core.StoredTerm`), returns `{:error, :gone}`, and
  its owner can only abandon it.

  A row its caller refused before it was stored never ran and has no input
  to run as it is: only a correction reopens it.
  """

  import Ash.Expr, only: [expr: 1]

  require Ash.Expr
  require Ash.Query

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.{Introspection, Owner, Runner}

  @doc """
  Reruns every row of `bulk_action` that has not succeeded. Returns `{:ok,
  bulk_action}`; `{:error, %{unmatched: ids}}` with nothing written when
  `:rows` names a row that is not one of them; or `{:error, error}` when
  refused.

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

    reopen(bulk_action, corrections, shared, opts, fn -> open_rows(bulk_action) end)
  end

  @doc """
  Reruns one failed `row` alone, the bulk action's other rows staying as
  they are, through the same run: its result is read as `retry/2`'s is.

  The run takes every row left unprocessed, so a bulk action that failed
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

    with :ok <- nothing_unprocessed(bulk_action) do
      reopen(bulk_action, %{row.id => correction}, %{}, opts, fn -> failed(row) end)
    end
  end

  @doc "The rows of `bulk_action` that have not succeeded, in the order they run."
  def open_rows(bulk_action) do
    Core.config(:row_resource)
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status != :succeeded)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp failed(row) do
    case Ash.get!(Core.config(:row_resource), row.id, authorize?: false) do
      %{status: :failed} = fresh -> [fresh]
      _finished -> []
    end
  end

  # Only a failed bulk action can have stopped short: every other retryable
  # one ran all its rows, and one running is refused by `:enqueue_retry`.
  defp nothing_unprocessed(%{status: :failed} = bulk_action) do
    Core.config(:row_resource)
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status in [:pending, :resolved])
    |> Ash.count!(authorize?: false)
    |> case do
      0 -> :ok
      count -> {:error, %{unprocessed: count}}
    end
  end

  defp nothing_unprocessed(_bulk_action), do: :ok

  defp reopen(bulk_action, corrections, shared, opts, rows) do
    with :ok <- Introspection.runnable(bulk_action),
         rows = rows.(),
         :ok <- Introspection.readable(rows),
         :ok <- all_known(corrections, rows) do
      write(rows, corrections, shared, bulk_action, opts)
    end
  end

  # The rows go first: each compares the shared input it ran with to the one
  # it will, so the bulk action must still hold the former. That is read here
  # rather than taken from the caller, whose copy may predate another retry:
  # one still saying `:running` would match no row, and nothing would run.
  defp write(rows, corrections, shared, bulk_action, opts) do
    resources = [Core.config(:bulk_action_resource), Core.config(:row_resource)]

    Ash.transaction(resources, fn ->
      current = Ash.get!(Core.config(:bulk_action_resource), bulk_action.id, authorize?: false)

      with :ok <- reopen_rows(rows, corrections, shared, current),
           {:ok, retried} <- enqueue(current, shared, opts) do
        retried
      else
        {:error, error} -> Ash.DataLayer.rollback(resources, error)
      end
    end)
    |> Core.nudge_poller()
  end

  defp all_known(corrections, rows) do
    case Map.keys(corrections) -- Enum.map(rows, & &1.id) do
      [] -> :ok
      unmatched -> {:error, %{unmatched: unmatched}}
    end
  end

  defp reopen_rows(rows, corrections, shared, bulk_action) do
    resource = Introspection.resource(bulk_action)

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      correction = Map.get(corrections, row.id, %{})

      case reopen_row(%{row | bulk_action: bulk_action}, correction, shared, resource) do
        {:ok, _row} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp reopen_row(%{refused: true} = row, correction, _shared, _resource)
       when map_size(correction) == 0,
       do: {:ok, row}

  defp reopen_row(row, correction, shared, resource) do
    arguments =
      correction
      |> Map.take([:input, :metadata, :error])
      |> put_target(row, correction, resource)
      |> put_shared_input(shared)

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
