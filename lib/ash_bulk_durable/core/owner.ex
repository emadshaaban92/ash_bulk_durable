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
  round-trip through `scope_from_worker_key/2` to `{:ok, scope}` with the
  same effective scope.
  """
  @callback worker_key(scope :: term()) :: term()

  @doc """
  `{:ok, scope}`, a usable scope from `worker_key/1`'s output acting in
  `tenant`, the tenant the bulk action was submitted in, read from the
  current DB state: if the user's roles there changed since submit, the
  worker runs with the new ones.

  `{:error, reason}` when the user can no longer act in `tenant` (gone, or
  removed from it): the worker writes every row that names no tenant of its
  own in `tenant` whatever the scope says, so a scope can't keep them out,
  only this can. A row that names its own tenant is guarded only by its
  target's policies. It is asked each time a run starts, and the start that
  gets `{:error, _}` fails the bulk action, `{:failed, %{reason:
  :access_revoked, term: inspect(reason)}}`, before that run's first row; a
  run already under way keeps its scope until it ends or restarts. A retry
  fails the same way until they can act there again.

  Return `{:error, _}` only for a definite refusal: it fails the bulk action
  for good. Raise for trouble that may pass (the database or an auth service
  briefly down), which is counted like any setup error.
  """
  @callback scope_from_worker_key(key :: term(), tenant :: term()) ::
              {:ok, scope :: term()} | {:error, reason :: term()}

  @doc "The configured owner's `worker_key/1`."
  def worker_key(scope), do: module!().worker_key(scope)

  @doc "The configured owner's `scope_from_worker_key/2`."
  def scope_from_worker_key(key, tenant) do
    module = module!()

    case module.scope_from_worker_key(key, tenant) do
      {:ok, _scope} = ok ->
        ok

      {:error, _reason} = error ->
        error

      other ->
        raise ArgumentError,
              "#{inspect(module)}.scope_from_worker_key/2 must return {:ok, scope} or " <>
                "{:error, reason}, got: #{inspect(other)}"
    end
  end

  defp module! do
    AshBulkDurable.Core.config(:owner_module) ||
      raise """
      ash_bulk_durable needs an `:owner_module` implementing `AshBulkDurable.Core.Owner`:

          config :ash_bulk_durable, owner_module: MyApp.BulkActions.Owner
      """
  end
end
