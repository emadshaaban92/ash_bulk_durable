defmodule Example.BulkActions.LocalStorage do
  @moduledoc """
  Storage on the local disk: the engine's `AshBulkDurable.Core.Storage`
  (`AshBulkDurable.Storage.Local`), the screens' `ExampleWeb.Bulk.Storage`, and
  the files rows extract. Swap it for an object store on more than one node
  without a shared volume.

  A "presigned" URL is a signed token `ExampleWeb.StorageController` honours,
  so the browser talks to storage the way it would to an object store.
  """
  use AshBulkDurable.Storage.Local

  @behaviour ExampleWeb.Bulk.Storage

  alias AshBulkDurable.Storage.Local

  @salt "storage"
  @default_expiry 3600

  @impl ExampleWeb.Bulk.Storage
  def upload(key, source, _opts), do: put_file(key, source, [])

  @doc "Whether an object sits at `key`."
  def exists?(key), do: File.exists?(path(key))

  @doc "Writes `body` at `key`, through `put_file/3` so it lands whole."
  def put_object(key, body) do
    source = Briefly.create!(prefix: "example_put_")

    try do
      with :ok <- File.write(source, body), do: put_file(key, source, [])
    after
      File.rm(source)
    end
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
    case Local.path(key) do
      {:ok, path} -> path
      {:error, :unsafe_key} -> raise ArgumentError, "unsafe storage key: #{inspect(key)}"
    end
  end

  defp url(grant), do: "/storage/" <> Phoenix.Token.sign(ExampleWeb.Endpoint, @salt, grant)
end
