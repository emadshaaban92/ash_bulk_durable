defmodule AshBulkDurable.TakeoverResolver do
  @moduledoc """
  An `AshBulkDurable.Core.Resolver` that resolves `value` to itself, and the
  first time it resolves after `hook/1`, runs the hook first: a test steps
  in between a run reading its `:pending` rows and flipping them.

  Likewise, the first `lost/2` after `lost_hook/1` runs that hook and then
  reports every value lost: a test steps in between a run reading its kept
  resolutions and forgetting them. Otherwise nothing is lost.
  """
  @behaviour AshBulkDurable.Core.Resolver

  @key {__MODULE__, :hook}
  @lost_key {__MODULE__, :lost_hook}

  @doc "Runs `fun` once, inside the next resolve."
  def hook(fun), do: :persistent_term.put(@key, fun)

  @doc "Runs `fun` once, inside the next `lost/2`, which then loses every value."
  def lost_hook(fun), do: :persistent_term.put(@lost_key, fun)

  @doc "Drops hooks that never ran."
  def clear do
    :persistent_term.erase(@key)
    :persistent_term.erase(@lost_key)
  end

  @impl true
  def prepare(_args, _context), do: {:ok, nil}

  @impl true
  def resolve(value, nil, _context) do
    run_once(@key)
    {:ok, value}
  end

  @impl true
  def lost(values, _context), do: if(run_once(@lost_key), do: values, else: [])

  # `erase/1` is true for one caller only, however many call at once.
  defp run_once(key) do
    with fun when is_function(fun, 0) <- :persistent_term.get(key, nil),
         true <- :persistent_term.erase(key) do
      fun.()
      true
    else
      _no_hook -> false
    end
  end

  @impl true
  def finish(nil), do: :ok
end
