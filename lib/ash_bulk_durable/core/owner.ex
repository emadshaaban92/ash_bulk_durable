defmodule AshBulkDurable.Core.Owner do
  @moduledoc """
  Who a bulk action belongs to, and how the worker acts as them again.

  The host implements it and names the module in config:

      config :ash_bulk_durable, owner_module: MyApp.BulkActions.Owner

  A bulk action is submitted with one scope and run by the worker in another
  process, often on another node, so it keeps `worker_key/1` of the submitter and the tenant
  they acted in, and the worker rebuilds a scope from those with
  `scope_from_worker_key/2`.
  """

  @doc """
  A stable identifier for the user behind `scope`: the partial-unique-index
  key on `BulkAction.user_id` and the prefix of their staging keys. Must
  round-trip through `scope_from_worker_key/2` to the same effective scope.
  """
  @callback worker_key(scope :: term()) :: term()

  @doc """
  A usable scope from `worker_key/1`'s output acting in `tenant`, the tenant
  the bulk action was submitted in, read from the current DB state: if the
  user's roles there changed since submit, the worker runs with the new ones,
  and if they can no longer act there, the scope must not reach it.
  """
  @callback scope_from_worker_key(key :: term(), tenant :: term()) :: term()

  @doc "The configured owner's `worker_key/1`."
  def worker_key(scope), do: module!().worker_key(scope)

  @doc "The configured owner's `scope_from_worker_key/2`."
  def scope_from_worker_key(key, tenant), do: module!().scope_from_worker_key(key, tenant)

  defp module! do
    AshBulkDurable.Core.config(:owner_module) ||
      raise """
      ash_bulk_durable needs an `:owner_module` implementing `AshBulkDurable.Core.Owner`:

          config :ash_bulk_durable, owner_module: MyApp.BulkActions.Owner
      """
  end
end
