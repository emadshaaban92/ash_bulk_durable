defmodule Example.Test.StorageHelpers do
  @moduledoc """
  Shared helpers for tests that swap global `:ash_bulk_durable` config, the
  storage adapter included. Swapping app env is global state, so these tests run `async: false`.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Point the `:ash_bulk_durable` storage adapter at `module` for the duration of
  the test, restoring the previous config on exit.
  """
  def put_storage(module), do: put_config(:storage, module)

  @doc "Sets one `:ash_bulk_durable` config key for the test, restoring it on exit."
  def put_config(key, value) do
    previous = Application.fetch_env(:ash_bulk_durable, key)
    Application.put_env(:ash_bulk_durable, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_bulk_durable, key, value)
        :error -> Application.delete_env(:ash_bulk_durable, key)
      end
    end)
  end

  @doc "Sets one `:bulk` config key for the test, restoring it on exit."
  def put_bulk_config(key, value) do
    previous = Application.get_env(:example, :bulk, [])
    Application.put_env(:example, :bulk, Keyword.put(previous, key, value))
    on_exit(fn -> Application.put_env(:example, :bulk, previous) end)
  end
end
