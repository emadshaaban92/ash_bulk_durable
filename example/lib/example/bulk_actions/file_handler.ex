defmodule Example.BulkActions.FileHandler do
  @moduledoc """
  Takes a `Example.Types.StoredFile` field from a sheet, or an array of them:
  the cell names files in a companion ZIP, separated by `|`. It becomes a
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
  def handles?(%Field{field: %{type: {:array, StoredFile}}}), do: true
  def handles?(%Field{}), do: false

  @impl AshBulkDurable.Sheet.FieldHandler
  def companion_requirement(%Field{}), do: %{accept: ~w(.zip), max_bytes: @max_zip_bytes}

  @impl AshBulkDurable.Sheet.FieldHandler
  def input_value(%Field{} = field, raw_value, _context) do
    names = raw_value |> to_string() |> String.split("|", trim: true) |> Enum.map(&String.trim/1)

    case Enum.reject(names, &(&1 == "")) do
      [] -> :skip
      filenames -> {:ok, {:resolve, FileResolver, reference(field, filenames)}}
    end
  end

  @impl AshBulkDurable.Sheet.FieldHandler
  def to_cell(_field, {:resolve, FileResolver, %{filenames: filenames}}),
    do: Enum.join(filenames, "|")

  def to_cell(_field, value), do: AshBulkDurable.Sheet.FieldHandler.cell(value)

  defp reference(%Field{field: %{name: name, type: {:array, _type}}}, filenames),
    do: %{field: name, filenames: filenames, many?: true}

  defp reference(%Field{field: %{name: name}}, filenames),
    do: %{field: name, filenames: filenames, many?: false}
end
