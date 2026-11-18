defmodule AshBulkDurable.Test.SideEffects do
  @moduledoc """
  Counts, by key, the runs of a side effect outside the database, which a
  rollback doesn't undo. A test calls `start/0`; with none started, `ran/1`
  counts nothing.
  """

  @table __MODULE__

  @doc "Starts counting, in a table the calling process owns."
  def start, do: :ets.new(@table, [:named_table, :public, :set])

  @doc "Counts one run for `key`."
  def ran(key) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.update_counter(@table, key, 1, {key, 0})

    :ok
  end

  @doc "The runs counted, by key."
  def counts, do: Map.new(:ets.tab2list(@table))
end
