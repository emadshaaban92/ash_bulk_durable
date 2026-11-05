defmodule Example.BulkActions.FileResolver do
  @moduledoc """
  Extracts the file a row names from the field's companion ZIP and stores it,
  resolving to the key the record keeps. `AshBulkDurable.Sheet.BoundedZip`
  reads the ZIP, because a user's archive can claim anything about itself.
  """
  @behaviour AshBulkDurable.Core.Resolver

  alias AshBulkDurable.Core.Resolver.Context
  alias AshBulkDurable.Sheet.BoundedZip
  alias Example.BulkActions.LocalStorage

  @max_file_bytes 10 * 1024 * 1024

  @impl true
  def prepare(args, %Context{staged_files: staged_files}) do
    args
    |> Enum.map(& &1.field)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, zips} ->
      case open(Map.get(staged_files, to_string(field)), field) do
        {:ok, zip} ->
          {:cont, {:ok, Map.put(zips, field, zip)}}

        {:error, error} ->
          finish(zips)
          {:halt, {:error, error}}
      end
    end)
  end

  @impl true
  def finish(zips), do: Enum.each(zips, fn {_field, zip} -> BoundedZip.close(zip) end)

  @impl true
  def resolve(%{field: field, filename: filename}, zips, _context) do
    zip = Map.fetch!(zips, field)
    key = "files/#{Ash.UUIDv7.generate()}#{Path.extname(filename)}"

    with {:ok, entry} <- entry(zip, filename),
         {:ok, body} <- extract(zip, entry, filename),
         :ok <- LocalStorage.put_object(key, body) do
      {:ok, key}
    end
  end

  defp open(nil, field), do: {:error, "no companion ZIP for #{field}"}
  defp open(path, _field), do: BoundedZip.open(path)

  defp entry(zip, filename) do
    case Map.fetch(zip.index, filename) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, "no file named #{inspect(filename)} in the companion ZIP"}
    end
  end

  defp extract(zip, entry, filename) do
    case BoundedZip.extract(zip, entry, @max_file_bytes) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "could not read #{inspect(filename)}: #{inspect(reason)}"}
    end
  end
end
