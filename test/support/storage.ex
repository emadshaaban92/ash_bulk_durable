defmodule AshBulkDurable.Test.Storage do
  @moduledoc """
  No-op `AshBulkDurable.Core.Storage` store wired in `config/test.exs`:
  reads and lists come back empty.

  Tests that need to *read back* what was written (companion download, the
  orphan sweep) override `:storage` with their own store — e.g.
  `AshBulkDurable.TestStorage` (in-memory) — for their duration.
  """
  @behaviour AshBulkDurable.Core.Storage

  @impl true
  def fetch_file(_key, _path, _opts), do: {:error, :not_stubbed}

  @impl true
  def delete_file(_key, _opts), do: :ok

  @impl true
  def list_files(_prefix, _opts), do: {:ok, []}
end
