defmodule AshBulkDurable.Test.Storage do
  @moduledoc """
  No-op `AshBulkDurable.Core.Storage` adapter wired in `config/test.exs`:
  reads and lists come back empty.

  Tests that need to *read back* what was written (companion download, the
  orphan sweep) override `:storage` with their own adapter — e.g.
  `AshBulkDurable.TestStorage` (in-memory) — for their duration.
  """
  @behaviour AshBulkDurable.Core.Storage

  @impl true
  def get_object(_key), do: {:error, :not_stubbed}

  @impl true
  def delete_object(_key), do: :ok

  @impl true
  def list_objects(_prefix), do: {:ok, []}
end
