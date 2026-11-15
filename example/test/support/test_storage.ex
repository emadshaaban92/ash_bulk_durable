defmodule Example.Test.TestStorage do
  @moduledoc """
  Agent-backed in-memory `AshBulkDurable.Core.Storage` adapter for tests. Lets a
  test seed staging objects (with a chosen `last_modified`) and then
  assert what `AshBulkDurable.Core.PurgeStaleStaging` left behind, without
  touching a real S3 bucket.

  Start it per-test (`start_supervised!(Example.Test.TestStorage)`) and
  point the framework at it by merging `storage: Example.Test.TestStorage`
  into the `:ash_bulk_durable` config for the test's duration.
  """
  @behaviour AshBulkDurable.Core.Storage
  @behaviour ExampleWeb.Bulk.Storage
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Seeds (or overwrites) one object. `last_modified` defaults to now;
  pass an older `DateTime` to make the object eligible for the 24h sweep.
  """
  def put(key, body \\ "x", last_modified \\ DateTime.utc_now()) do
    Agent.update(__MODULE__, &Map.put(&1, key, %{body: body, last_modified: last_modified}))
  end

  @doc "What `Example.BulkActions.FileResolver` writes and asks of a store."
  def put_object(key, body) do
    put(key, body)
    :ok
  end

  def exists?(key), do: Agent.get(__MODULE__, &Map.has_key?(&1, key))

  @doc "Currently-stored keys, for assertions."
  def keys, do: Agent.get(__MODULE__, &Map.keys(&1))

  @impl true
  def fetch_file(key, path, _opts) do
    case get_object(key) do
      {:ok, body} -> File.write(path, body)
      error -> error
    end
  end

  @doc "The bytes stored at `key`, for assertions."
  def get_object(key) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil -> {:error, :not_found}
      %{body: body} -> {:ok, body}
    end
  end

  @impl true
  def delete_file(key, _opts) do
    Agent.update(__MODULE__, &Map.delete(&1, key))
    :ok
  end

  @impl true
  def list_files(prefix, _opts) do
    objects =
      __MODULE__
      |> Agent.get(& &1)
      |> Enum.filter(fn {key, _meta} -> String.starts_with?(key, prefix) end)
      |> Enum.map(fn {key, %{last_modified: last_modified}} ->
        %{key: key, last_modified: last_modified}
      end)

    {:ok, objects}
  end

  @impl true
  def presigned_put_url(key, _opts), do: "https://test.local/put/#{key}"

  @impl true
  def presigned_get_url(key, _opts), do: "https://test.local/get/#{key}"

  @impl true
  def upload(key, path, _opts) do
    put(key, File.read!(path))
    :ok
  end
end

defmodule Example.Test.SlowStorage do
  @moduledoc """
  `Example.Test.TestStorage`, with a write that takes a second for a file whose
  bytes say slow: a large file on a slow link, away from any database call,
  which is where a resolver spends its time.
  """
  alias Example.Test.TestStorage

  def put_object(key, body) do
    if body =~ "slow", do: Process.sleep(1000)
    TestStorage.put_object(key, body)
  end

  defdelegate fetch_file(key, path, opts), to: TestStorage
  defdelegate delete_file(key, opts), to: TestStorage
  defdelegate list_files(prefix, opts), to: TestStorage
  defdelegate exists?(key), to: TestStorage
  defdelegate presigned_put_url(key, opts), to: TestStorage
  defdelegate presigned_get_url(key, opts), to: TestStorage
  defdelegate upload(key, path, opts), to: TestStorage
end

defmodule Example.Test.GatedStorage do
  @moduledoc """
  `Example.Test.TestStorage`, whose first `width` writes wait for each other,
  for up to a second, and which keeps the most it saw at once: a test can
  tell how many rows phase 1 extracts together. `start/1` makes its table, in
  the calling process.
  """
  alias Example.Test.TestStorage

  @table __MODULE__

  def start(width) do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.insert(@table, [{:width, width}, {:at_once, 0}, {:most, 0}, {:arrived, 0}])
  end

  @doc "The most writes seen at once."
  def most, do: :ets.lookup_element(@table, :most, 2)

  def put_object(key, body) do
    at_once = :ets.update_counter(@table, :at_once, 1)
    :ets.select_replace(@table, [{{:most, :"$1"}, [{:<, :"$1", at_once}], [{{:most, at_once}}]}])
    arrived = :ets.update_counter(@table, :arrived, 1)
    await(arrived, System.monotonic_time(:millisecond) + 1000)
    :ets.update_counter(@table, :at_once, -1)
    TestStorage.put_object(key, body)
  end

  # The first `width` writes to arrive wait for each other; the rest pass.
  defp await(arrived, deadline) do
    width = :ets.lookup_element(@table, :width, 2)

    if arrived <= width and :ets.lookup_element(@table, :arrived, 2) < width and
         System.monotonic_time(:millisecond) < deadline do
      Process.sleep(1)
      await(arrived, deadline)
    end
  end

  defdelegate fetch_file(key, path, opts), to: TestStorage
  defdelegate delete_file(key, opts), to: TestStorage
  defdelegate list_files(prefix, opts), to: TestStorage
  defdelegate exists?(key), to: TestStorage
  defdelegate presigned_put_url(key, opts), to: TestStorage
  defdelegate presigned_get_url(key, opts), to: TestStorage
  defdelegate upload(key, path, opts), to: TestStorage
end
