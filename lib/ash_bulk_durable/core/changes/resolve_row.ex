defmodule AshBulkDurable.Core.Changes.ResolveRow do
  @moduledoc """
  Drives one `Row` through the `:resolve` action (phase 1).

  Resolving the row's input references (records looked up, staged files
  extracted and stored, …) happens in a **`before_transaction` hook**, so
  it is *outside* the row's DB transaction — no connection is held while
  waiting on S3. The resolved values are merged into `resolved_data`, a
  tenant the worker resolved for the row is kept in `resolved_tenant`, and
  the row flips to `:resolved`, all inside the (tiny) write transaction.

  The worker drives one `Ash.update(row, :resolve)` per row inside
  `Task.async_stream`, so resolution runs concurrently across rows while
  each row's write is its own short transaction. The chunk's
  `AshBulkDurable.Core.Runner.Settings` (in the row's tenant), its prepared
  resolvers and the row's tenant ride in on the action `context` under
  `:ash_bulk_durable` (same pattern as the `:run` action), so the change
  doesn't rebuild them per row.

  A row with a reference that can't be resolved fails the update (the row
  is left `:pending` and the worker marks it `:failed`).
  """
  use Ash.Resource.Change
  require Ash.Expr

  alias AshBulkDurable.Core.{BulkActionLock, Runner}

  @impl true
  def change(changeset, _opts, _context) do
    %{settings: settings, resolvers: resolvers} = Map.fetch!(changeset.context, :ash_bulk_durable)

    Ash.Changeset.before_transaction(changeset, fn cs ->
      case Runner.resolve_references(settings, cs.data, resolvers) do
        {:ok, resolutions} ->
          merged = Map.merge(cs.data.resolved_data || %{}, resolutions)

          cs
          |> Ash.Changeset.force_change_attribute(:resolved_data, merged)
          |> keep_tenant(settings)
          |> Ash.Changeset.force_change_attribute(:status, :resolved)
          |> give_back_attempt(settings)

        {:error, error} ->
          Ash.Changeset.add_error(cs, resolve_error(error))
      end
    end)
  end

  # A row resolved alone was bumped for this run, and phase 2 bumps it again
  # for its own: this run's bump goes back, so one run counts once. Bumps
  # earlier runs died with stay, so a row whose resolution is lost between
  # runs still reaches the cap. Chunks only hold rows with no attempts.
  #
  # The give-back is `attempts - 1` on the committed count, never below 0,
  # and the same transaction stops naming the row as the one being isolated,
  # so a later shutdown can't give the bump back again.
  defp give_back_attempt(%{data: %{attempts: attempts}} = changeset, settings)
       when attempts > 0 do
    changeset
    |> Ash.Changeset.atomic_update(
      :attempts,
      Ash.Expr.expr(if attempts > 0, do: attempts - 1, else: 0)
    )
    |> Ash.Changeset.before_action(&stop_isolating(&1, settings))
  end

  defp give_back_attempt(changeset, _settings), do: changeset

  # The bulk action first, then the row (R1), and never waiting: under a
  # lock another transaction holds, or once the bulk action has moved on to
  # another row or pass, there is nothing of this run's to clear.
  defp stop_isolating(%{data: row} = changeset, settings) do
    filter = Ash.Expr.expr(pass == ^settings.pass and isolating_row_id == ^row.id)

    case BulkActionLock.lock(row.bulk_action_id, [:running], filter: filter) do
      {:ok, locked} ->
        {:ok, _cleared, _notifications} =
          Ash.update(locked, %{isolating_row_id: nil},
            action: :count_crashes,
            authorize?: false,
            return_notifications?: true
          )

      :none ->
        :ok
    end

    changeset
  end

  # Only a tenant the row's target named by reference needs keeping; any
  # other is read from the target or the bulk action again.
  defp keep_tenant(changeset, settings) do
    case Runner.unresolved_tenant(changeset.data) do
      nil ->
        changeset

      _reference ->
        Ash.Changeset.force_change_attribute(changeset, :resolved_tenant, settings.tenant)
    end
  end

  # An exception (a lookup that matched nothing, a refused read) is kept as
  # it is, so the screens can word it; a resolver's human-readable string
  # (e.g. "no file named …") surfaces verbatim; anything else is inspected
  # behind a generic prefix.
  defp resolve_error(error) when is_exception(error), do: error
  defp resolve_error(message) when is_binary(message), do: [message: message]
  defp resolve_error(term), do: [message: "resolution failed: #{inspect(term)}"]
end
