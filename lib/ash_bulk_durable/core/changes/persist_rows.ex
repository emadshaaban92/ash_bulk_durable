defmodule AshBulkDurable.Core.Changes.PersistRows do
  @moduledoc """
  After-action change on `BulkAction.:create` that bulk-inserts one `Row`
  per element of the `rows` argument: `%{target:, input:, metadata:,
  error:}`, every key optional.

  A row with no input of its own keeps `nil` and runs with the bulk action's.
  A row holding no reference, in the input it runs with or its tenant, is
  born `:resolved`, so the worker's resolve phase never reads it; a row whose
  caller already refused it (`error`) is born `:failed` and `refused`.

  Runs inside the create action's transaction so a row-insert failure rolls
  back the `BulkAction` as well. Reads the destination resource from
  `:row_resource` config so the core stays decoupled from the host's module
  name.
  """
  use Ash.Resource.Change

  alias AshBulkDurable.Core.Runner

  @impl true
  def change(changeset, _opts, context) do
    rows = Ash.Changeset.get_argument(changeset, :rows) || []

    Ash.Changeset.after_action(changeset, fn _changeset, bulk_action ->
      persist(bulk_action, rows, context)
    end)
  end

  defp persist(bulk_action, rows, context) do
    row_resource = AshBulkDurable.Core.config(:row_resource)

    inputs =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        %{
          bulk_action_id: bulk_action.id,
          row_index: index,
          target: Map.get(row, :target),
          input: row |> Map.get(:input) |> Runner.stored_input(),
          metadata: Map.get(row, :metadata) || %{},
          error: Map.get(row, :error),
          refused: not is_nil(Map.get(row, :error)),
          resolved_data: %{},
          status: Runner.initial_status(row, bulk_action.input)
        }
      end)

    result =
      Ash.bulk_create(inputs, row_resource, :create,
        actor: context.actor,
        authorize?: false,
        return_errors?: true,
        return_records?: false,
        stop_on_error?: true,
        transaction: false
      )

    case result do
      %{status: :success} ->
        {:ok, bulk_action}

      %{errors: errors} ->
        # Wrap as a proper Ash error class so the nested per-row
        # validation/constraint errors keep their fidelity.
        {:error, Ash.Error.to_error_class(errors, bread_crumbs: "persist_rows_failed")}
    end
  end
end
