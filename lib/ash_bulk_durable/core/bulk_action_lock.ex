defmodule AshBulkDurable.Core.BulkActionLock do
  @moduledoc """
  Holds a bulk action's row for the rest of the current transaction.

  Nothing writes a bulk action's rows without first holding the lock on that
  bulk action's row. The lock order is always: the bulk action, then its
  rows. Two writers taking them in that order wait on the bulk action alone,
  so neither can hold a row the other is waiting for.

  The lock is `FOR NO KEY UPDATE`: it excludes another writer of the bulk
  action, but not the foreign-key checks other transactions make against
  `bulk_actions`, such as a row insert or update naming it, which take only
  `FOR KEY SHARE`. `SKIP LOCKED` makes a bulk action someone else holds read
  as absent, so the caller is refused at once rather than waiting.
  """

  require Ash.Query

  alias AshBulkDurable.Core

  @doc """
  Locks the bulk action `id` while its status is one of `statuses` and it
  matches `:filter`, an Ash filter expression (none by default). Returns
  `{:ok, bulk_action}`, or `:none` when it is locked by another transaction,
  missing, in another status, or not matching `:filter`.

  With `:wait`, milliseconds, it waits that long for another transaction's
  lock instead (`SET LOCAL lock_timeout`), then raises. Only the poller's
  shutdown does, for a run it has just killed, whose transaction lets go a
  moment later: everything else refuses at once.

  Raises `ArgumentError` outside a transaction, where the lock would hold
  nothing.
  """
  def lock(id, statuses, opts \\ []) do
    resource = Core.config(:bulk_action_resource)
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)

    unless repo.in_transaction?() do
      raise ArgumentError, "a bulk action is locked only inside a transaction"
    end

    resource
    |> Ash.Query.filter(id == ^id and status in ^statuses)
    |> Ash.Query.do_filter(Keyword.get(opts, :filter, true))
    |> Ash.Query.lock(lock_clause(repo, opts[:wait]))
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> :none
      bulk_action -> {:ok, bulk_action}
    end
  end

  defp lock_clause(_repo, nil), do: "FOR NO KEY UPDATE SKIP LOCKED"

  defp lock_clause(repo, wait) when is_integer(wait) and wait > 0 do
    repo.query!("SET LOCAL lock_timeout = '#{wait}ms'")
    "FOR NO KEY UPDATE"
  end
end
