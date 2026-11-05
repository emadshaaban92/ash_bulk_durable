defmodule AshBulkDurable.Core do
  @moduledoc """
  The engine's core: durable bulk actions kept as `BulkAction` and `Row`
  records and run by an Oban worker. A row is a target and an input; where
  the rows came from is the caller's. Ash, Oban and Postgres only; nothing
  here names a layer above it.

  ## Configuration

      config :ash_bulk_durable,
        bulk_action_resource: MyApp.BulkActions.BulkAction,
        row_resource: MyApp.BulkActions.Row
  """

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  alias AshBulkDurable.Core.{Introspection, Owner, Retry, Runner}

  @doc """
  Creates a bulk action running `action` of `resource` over `rows`, writing
  the bulk action, its rows and its job in one transaction. A row is
  `%{target:, input:, metadata:, error:}`, every key optional (see
  `AshBulkDurable.Core.Runner`). Returns `{:ok, bulk_action}`, or `{:error,
  error}` with nothing written.

  Options:

    * `:scope` (required) — who runs it; its owner keeps the bulk action.
    * `:tenant` — the tenant it acts in, which a row whose target names none
      acts in; without one, the tenant `scope` acts in now. Kept, so a run
      or a retry acts there wherever the owner has moved to since.
    * `:input` — the input a row with none of its own runs with, stored once;
      a row's own replaces it rather than merging into it.
    * `:mode` — `:per_row` (default) or `:all_or_nothing`.
    * `:chunk_size` — rows a per-row bulk action commits per batch.
    * `:staged_files` — `%{name => storage_key}`: files staged for the
      resolvers, deleted once the bulk action no longer needs them.
    * `:metadata` — a map kept on the bulk action and never read here.

  Raises `ArgumentError` when `resource` is not an Ash resource or has no
  `action`.
  """
  def create(resource, action, rows, opts) do
    action = action!(resource, action)
    rows = Enum.to_list(rows)
    scope = Keyword.fetch!(opts, :scope)

    Ash.create(
      config(:bulk_action_resource),
      %{
        user_id: Owner.worker_key(scope),
        resource_name: Introspection.resource_name(resource),
        action_name: action.name,
        action_type: action.type,
        tenant: Keyword.get_lazy(opts, :tenant, fn -> Runner.scope_tenant(scope) end),
        input: opts |> Keyword.get(:input) |> Runner.stored_input(),
        staged_files: Keyword.get(opts, :staged_files, %{}),
        metadata: Keyword.get(opts, :metadata, %{}),
        total_rows: length(rows),
        mode: Keyword.get(opts, :mode, :per_row),
        chunk_size:
          Keyword.get_lazy(opts, :chunk_size, fn -> config(:default_chunk_size, 50) end),
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  defp action!(resource, action) do
    unless Ash.Resource.Info.resource?(resource),
      do: raise(ArgumentError, "#{inspect(resource)} is not an Ash resource")

    Ash.Resource.Info.action(resource, action) ||
      raise ArgumentError, "#{inspect(resource)} has no action #{inspect(action)}"
  end

  @doc """
  Abandons `bulk_action`: its rows that have not succeeded are never run,
  and it frees its owner to start another. Only a bulk action that finished
  with failed rows is abandoned; one queued or running, or already
  finished, is refused, as is one `scope`'s owner does not own. Returns
  `{:ok, bulk_action}` or `{:error, error}`.
  """
  def abandon(bulk_action, opts) do
    owner = Owner.worker_key(Keyword.fetch!(opts, :scope))

    bulk_action
    |> Ash.Changeset.for_update(:mark_finished, %{result: :cancelled}, authorize?: false)
    |> Ash.Changeset.filter(expr(status == :completed_with_errors and user_id == ^owner))
    |> Ash.update(authorize?: false)
  end

  @doc "Reruns the rows that have not succeeded; see `AshBulkDurable.Core.Retry.retry/2`."
  defdelegate retry(bulk_action, opts), to: Retry

  @doc "Reruns one failed row alone; see `AshBulkDurable.Core.Retry.retry_row/2`."
  defdelegate retry_row(row, opts), to: Retry

  @doc "The rows that have not succeeded; see `AshBulkDurable.Core.Retry.open_rows/1`."
  defdelegate open_rows(bulk_action), to: Retry

  @doc """
  The `:action_source` a bulk action's writes carry in their context, and
  that a screen asking `Ash.can?` on its behalf passes too, so one policy
  answers both.
  """
  def action_source, do: :ash_bulk_durable

  @doc "Reads one `ash_bulk_durable` config key."
  @spec config(atom(), term()) :: term()
  def config(key, default \\ nil), do: Application.get_env(:ash_bulk_durable, key, default)

  @doc """
  The name of the Oban instance the engine enqueues, reads and cancels its
  jobs through: `:oban` in the config, `Oban` by default. Every job call goes
  through that instance's config, so its `:prefix` is honoured.
  """
  @spec oban() :: Oban.name()
  def oban, do: config(:oban, Oban)
end
