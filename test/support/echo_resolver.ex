defmodule AshBulkDurable.EchoResolver do
  @moduledoc """
  An `AshBulkDurable.Core.Resolver` that resolves `{:resolve, EchoResolver,
  value}` to `value`, so a core test can hold a reference without a staged
  file behind it.
  """
  @behaviour AshBulkDurable.Core.Resolver

  @impl true
  def prepare(_args, _context), do: {:ok, nil}

  @impl true
  def resolve(value, nil, _context), do: {:ok, value}

  @impl true
  def finish(nil), do: :ok
end
