defmodule AshBulkDurable.Test.StoredFile do
  @moduledoc "A file's key, its own type so `AshBulkDurable.Test.FilesHandler` can claim it."
  use Ash.Type.NewType, subtype_of: :string
end

defmodule AshBulkDurable.Test.FilesHandler do
  @moduledoc """
  Takes a field of files from a sheet, the shape an app's own handler has: the
  cell names files in a companion ZIP, separated by `|`, and becomes a
  reference a resolver answers when the row runs.
  """
  use AshBulkDurable.Sheet.FieldHandler

  alias AshBulkDurable.EchoResolver
  alias AshBulkDurable.Sheet.Field
  alias AshBulkDurable.Test.StoredFile

  @impl AshBulkDurable.Sheet.FieldHandler
  def handles?(%Field{field: %{type: {:array, StoredFile}}}), do: true
  def handles?(%Field{}), do: false

  @impl AshBulkDurable.Sheet.FieldHandler
  def companion_requirement(%Field{}), do: %{accept: ~w(.zip), max_bytes: 1024 * 1024}

  @impl AshBulkDurable.Sheet.FieldHandler
  def input_value(%Field{}, raw_value, _context) do
    case raw_value |> to_string() |> String.split("|", trim: true) do
      [] -> :skip
      filenames -> {:ok, {:resolve, EchoResolver, %{filenames: filenames}}}
    end
  end

  @impl AshBulkDurable.Sheet.FieldHandler
  def to_cell(_field, {:resolve, EchoResolver, %{filenames: filenames}}),
    do: Enum.join(filenames, "|")

  def to_cell(_field, value), do: AshBulkDurable.Sheet.FieldHandler.cell(value)
end

defmodule AshBulkDurable.Test.Note do
  @moduledoc "A type over a string, which a sheet reads as one."
  use Ash.Type.NewType, subtype_of: :string
end

defmodule AshBulkDurable.Test.Blob do
  @moduledoc "A type of its own, no primitive under it, which no default handler claims."
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :binary

  @impl true
  def cast_input(value, _constraints), do: {:ok, value}

  @impl true
  def cast_stored(value, _constraints), do: {:ok, value}

  @impl true
  def dump_to_native(value, _constraints), do: {:ok, value}
end

defmodule AshBulkDurable.Test.PhotoEmbed do
  @moduledoc "An embedded value, which a cell cannot hold."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :url, :string, public?: true
  end
end
