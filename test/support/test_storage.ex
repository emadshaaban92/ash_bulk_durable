defmodule AshBulkDurable.TestStorage do
  @moduledoc """
  Agent-backed in-memory `AshBulkDurable.Core.Storage` adapter for tests. Lets a
  test seed staging objects (with a chosen `last_modified`) and then
  assert what `AshBulkDurable.Core.PurgeStaleStaging` left behind, without
  touching a real S3 bucket.

  Start it per-test (`start_supervised!(AshBulkDurable.TestStorage)`) and
  point the framework at it by merging `storage: AshBulkDurable.TestStorage`
  into the `:ash_bulk_durable` config for the test's duration.
  """
  @behaviour AshBulkDurable.Core.Storage
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

  @doc "Currently-stored keys, for assertions."
  def keys, do: Agent.get(__MODULE__, &Map.keys(&1))

  @impl true
  def get_object(key) do
    case Agent.get(__MODULE__, &Map.get(&1, key)) do
      nil -> {:error, :not_found}
      %{body: body} -> {:ok, body}
    end
  end

  @impl true
  def delete_object(key) do
    Agent.update(__MODULE__, &Map.delete(&1, key))
    :ok
  end

  @impl true
  def list_objects(prefix) do
    objects =
      __MODULE__
      |> Agent.get(& &1)
      |> Enum.filter(fn {key, _meta} -> String.starts_with?(key, prefix) end)
      |> Enum.map(fn {key, %{last_modified: last_modified}} ->
        %{key: key, last_modified: last_modified}
      end)

    {:ok, objects}
  end
end
