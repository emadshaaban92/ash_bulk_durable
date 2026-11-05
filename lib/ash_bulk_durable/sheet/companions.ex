defmodule AshBulkDurable.Sheet.Companions do
  @moduledoc """
  Checks the files staged beside a sheet before it is staged as a bulk
  action, whoever stages it.

    * **Every key is the owner's.** A key must start with
      `bulk-staging/<owner>/` and hold no `..` segment. Keys are computed by
      the server that presigned their upload, never supplied by a browser,
      so this defends against a forged submit naming another user's staged
      files, or a key such as `bulk-staging/<owner>/../../public/x` that
      starts with the prefix yet escapes it.
    * **Every requirement is met.** A mapped field whose handler has a
      `companion_requirement/1` needs a file staged under its name, with an
      extension the requirement accepts. Its size is not checked here: the
      bytes are not, and the upload that wrote them is what can refuse an
      oversized file (the screens' presigned upload signs its length).
  """

  alias AshBulkDurable.Sheet
  alias AshBulkDurable.Sheet.Mapping

  @doc "`:ok`, or `{:error, error}` naming the first companion refused."
  def check(%Mapping{} = mapping, companions, owner) do
    prefix = "bulk-staging/#{owner}/"

    with :ok <- check_keys(companions, prefix) do
      check_fields(mapping, companions)
    end
  end

  defp check_fields(mapping, companions) do
    mapping
    |> Mapping.fields()
    |> Enum.reduce_while(:ok, fn field, :ok ->
      case check_field(field, companions) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, refuse(field.field.name, message)}
      end
    end)
  end

  defp check_keys(companions, prefix) do
    case Enum.find(companions, fn {_name, key} -> not safe_key?(key, prefix) end) do
      nil ->
        :ok

      {name, _key} ->
        refuse(
          name,
          "every companion key must start with \"#{prefix}\" and contain no \"..\" segment"
        )
    end
  end

  defp check_field(field, companions) do
    case Sheet.handler_for(field).companion_requirement(field) do
      nil -> :ok
      requirement -> meets(staged(companions, field.field.name), requirement)
    end
  end

  defp staged(companions, name),
    do: Map.get(companions, name) || Map.get(companions, to_string(name))

  defp meets(nil, _requirement), do: {:error, "no file is staged for it"}

  defp meets(key, %{accept: accept}) do
    if String.downcase(Path.extname(key)) in Enum.map(accept, &String.downcase/1),
      do: :ok,
      else: {:error, "its file must be one of #{Enum.join(accept, ", ")}"}
  end

  defp safe_key?(key, prefix) when is_binary(key) do
    String.starts_with?(key, prefix) and ".." not in Path.split(key)
  end

  defp safe_key?(_key, _prefix), do: false

  defp refuse(name, message) do
    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(field: name, message: message)
     )}
  end
end
