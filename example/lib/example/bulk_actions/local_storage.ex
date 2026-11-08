defmodule Example.BulkActions.LocalStorage do
  @moduledoc """
  Storage on the local disk: the engine's `AshBulkDurable.Core.Storage`, the
  screens' `ExampleWeb.Bulk.Storage`, and the files rows extract. Swap it for
  an object store in a real deployment.

  A "presigned" URL is a signed token `ExampleWeb.StorageController` honours,
  so the browser talks to storage the way it would to an object store.
  """
  @behaviour AshBulkDurable.Core.Storage
  @behaviour ExampleWeb.Bulk.Storage

  @salt "storage"
  @default_expiry 3600

  @impl AshBulkDurable.Core.Storage
  def fetch_file(key, dest, _opts), do: File.cp(path(key), dest)

  @impl AshBulkDurable.Core.Storage
  def delete_file(key, _opts) do
    case File.rm(path(key)) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @impl AshBulkDurable.Core.Storage
  def list_files(prefix, _opts) do
    objects =
      for file <- Path.wildcard(path(prefix) <> "/**"), File.regular?(file) do
        %{
          key: Path.relative_to(file, root()),
          last_modified:
            file |> File.stat!(time: :posix) |> Map.fetch!(:mtime) |> DateTime.from_unix!()
        }
      end

    {:ok, objects}
  end

  @impl ExampleWeb.Bulk.Storage
  def upload(key, source, _opts) do
    target = path(key)
    File.mkdir_p!(Path.dirname(target))
    File.cp(source, target)
  end

  @doc "Whether an object sits at `key`."
  def exists?(key), do: File.exists?(path(key))

  @doc "Writes `body` at `key`."
  def put_object(key, body) do
    target = path(key)
    File.mkdir_p!(Path.dirname(target))
    File.write(target, body)
  end

  @impl ExampleWeb.Bulk.Storage
  def presigned_put_url(key, opts) do
    url(%{method: :put, key: key, max_bytes: opts[:content_length]})
  end

  @impl ExampleWeb.Bulk.Storage
  def presigned_get_url(key, opts) do
    disposition =
      opts
      |> Keyword.get(:query_params, [])
      |> List.keyfind("response-content-disposition", 0, {nil, "attachment"})
      |> elem(1)

    url(%{method: :get, key: key, disposition: disposition})
  end

  @doc "What a token grants, or `:error`."
  def verify(token) do
    case Phoenix.Token.verify(ExampleWeb.Endpoint, @salt, token, max_age: @default_expiry) do
      {:ok, grant} -> {:ok, grant}
      {:error, _reason} -> :error
    end
  end

  @doc "Where `key` sits on disk."
  def path(key) do
    case Path.safe_relative(key) do
      {:ok, relative} -> Path.join(root(), relative)
      :error -> raise ArgumentError, "unsafe storage key: #{inspect(key)}"
    end
  end

  defp url(grant), do: "/storage/" <> Phoenix.Token.sign(ExampleWeb.Endpoint, @salt, grant)

  defp root, do: Application.get_env(:example, :storage_dir, "priv/storage")
end
