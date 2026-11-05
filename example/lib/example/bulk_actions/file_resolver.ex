defmodule Example.BulkActions.FileResolver do
  @moduledoc """
  Extracts the files a row names from the field's companion ZIP and stores
  them, resolving to the keys the record keeps. `AshBulkDurable.Sheet.BoundedZip`
  reads the ZIP, because a user's archive can claim anything about itself.
  """
  @behaviour AshBulkDurable.Core.Resolver

  alias AshBulkDurable.Core.Resolver.Context
  alias AshBulkDurable.Sheet.BoundedZip

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
  def resolve(%{field: field, filenames: filenames, many?: many?}, zips, _context) do
    zip = Map.fetch!(zips, field)

    filenames
    |> Enum.reduce_while({:ok, []}, fn filename, {:ok, keys} ->
      case store(zip, filename) do
        {:ok, key} -> {:cont, {:ok, [key | keys]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> value(many?)
  end

  # A key the store no longer holds was swept while its row waited for a
  # correction. A value is one field's files, kept or extracted whole.
  @impl true
  def lost(resolved, _context) do
    storage = storage()
    Enum.reject(resolved, fn value -> value |> List.wrap() |> Enum.all?(&storage.exists?/1) end)
  end

  defp store(zip, filename) do
    key = "files/#{Ash.UUIDv7.generate()}#{Path.extname(filename)}"

    with {:ok, entry} <- entry(zip, filename),
         {:ok, body} <- extract(zip, entry, filename),
         :ok <- storage().put_object(key, body) do
      {:ok, key}
    end
  end

  defp value({:ok, keys}, true), do: {:ok, Enum.reverse(keys)}
  defp value({:ok, [key]}, false), do: {:ok, key}
  defp value({:error, error}, _many?), do: {:error, error}

  defp storage, do: AshBulkDurable.config(:storage)

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
