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

  alias AshBulkDurable.Core.Runner

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

        {:error, error} ->
          Ash.Changeset.add_error(cs, resolve_error(error))
      end
    end)
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
