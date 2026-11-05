defmodule Example.BulkActions.FileHandler do
  @moduledoc """
  Takes a `Example.Types.StoredFile` field from a sheet: the cell names a file,
  and the column asks for a companion ZIP holding them. The cell becomes a
  reference `Example.BulkActions.FileResolver` resolves when the row runs; an
  empty cell sends nothing.
  """
  use AshBulkDurable.Sheet.FieldHandler

  alias AshBulkDurable.Sheet.Field
  alias Example.BulkActions.FileResolver
  alias Example.Types.StoredFile

  @max_zip_bytes 100 * 1024 * 1024

  @impl AshBulkDurable.Sheet.FieldHandler
  def handles?(%Field{field: %{type: StoredFile}}), do: true
  def handles?(%Field{}), do: false

  @impl AshBulkDurable.Sheet.FieldHandler
  def companion_requirement(%Field{}), do: %{accept: ~w(.zip), max_bytes: @max_zip_bytes}

  @impl AshBulkDurable.Sheet.FieldHandler
  def input_value(%Field{} = field, raw_value, _context) do
    case String.trim(to_string(raw_value)) do
      "" -> :skip
      filename -> {:ok, {:resolve, FileResolver, %{field: field.field.name, filename: filename}}}
    end
  end

  @impl AshBulkDurable.Sheet.FieldHandler
  def to_cell(_field, {:resolve, FileResolver, %{filename: filename}}), do: filename
  def to_cell(_field, value), do: AshBulkDurable.Sheet.FieldHandler.cell(value)
end
