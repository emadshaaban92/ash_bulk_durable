defmodule AshBulkDurable do
  @moduledoc """
  The entry point to `ash_bulk_durable`. It holds no logic: each function
  hands its call to the layer that owns it, so a caller names one module
  whichever layer serves it. The engine itself is `AshBulkDurable.Core`;
  spreadsheets are `AshBulkDurable.Sheet`'s.

  The verbs are Ash's, with its argument orders, and each returns `{:ok,
  bulk_action}` once the bulk action and its rows are written in one
  transaction; a node's `AshBulkDurable.Core.Poller` runs it afterwards. A verb takes a list of
  inputs or a `%AshBulkDurable.Sheet{}` from `read_sheet/2`, told apart by
  the argument:

      AshBulkDurable.bulk_create([%{title: "Hello"}], Post, :create, scope: scope)

      {:ok, sheet} = AshBulkDurable.read_sheet("posts.csv")

      AshBulkDurable.update_many(sheet, Post, :update,
        identity: :slug,
        mapping: [columns: %{slug: "Slug", title: "Title"}],
        scope: scope
      )

  A selection is a query or a list, with one input for every row:

      AshBulkDurable.bulk_update(query, :retitle, %{title: "Hello"}, scope: scope)

      AshBulkDurable.bulk_destroy(ids, :destroy, resource: Post, scope: scope)

  ## Options

    * `:scope` (required) — who runs it; the bulk action is theirs, and the
      worker acts as them.
    * `:tenant` — the tenant a row acts in; without one, the tenant `:scope`
      acts in now, which a later run or retry keeps.
    * `:mode` — `:per_row` (default) commits each row on its own and keeps
      failures to correct; `:all_or_nothing` is one transaction.
    * `:chunk_size` — rows a `:per_row` bulk action commits per batch.
    * `:identity` — for `update_many/4` and `destroy_many/4`, the identity
      a target is found by; without it a target is a record or its primary
      key.
    * `:resource` — for `bulk_update/4` and `bulk_destroy/4`, the resource a
      list of primary keys belongs to; a query and a record know theirs.

  A sheet also takes:

    * `:mapping` — `:columns` (`%{field => header}`, or `%{field => %{key
      => header}}` for a relationship looked up by a composite identity),
      `:rel_identities` (`%{relationship => identity}`, the identity a
      relationship's cell is looked up by) and `:tenant_mapping`, the
      column naming each row's tenant; see `AshBulkDurable.Sheet.Mapping`.
    * `:companions` — `%{field => storage_key}`, files staged for fields
      that need one.
  """

  alias AshBulkDurable.{Core, Sheet}
  alias AshBulkDurable.Sheet.{ErrorsSheet, Mapping}

  defdelegate action_source(), to: Core
  defdelegate config(key, default \\ nil), to: Core

  @doc "Reads a CSV or XLSX; see `AshBulkDurable.Sheet.read/2`."
  defdelegate read_sheet(path, opts \\ []), to: Sheet, as: :read

  @doc """
  Creates a record per input, as `Ash.bulk_create/4`: `inputs` is a list of
  input maps, or a sheet whose mapped columns give each row's input. An
  input in a list can be `{%{tenant: tenant}, input}`, for a row acting in a
  tenant of its own, a value or a `{:lookup, resource, identity, value}`.
  """
  def bulk_create(inputs_or_sheet, resource, action, opts),
    do: start(inputs_or_sheet, resource, action, :create, opts)

  @doc """
  Updates each target with its own input, as `Ash.update_many/4`:
  `targets` is a list of `{target, input}`, or a sheet whose identity
  columns find each row's record and whose other mapped columns give its
  input. A target is a record, its primary key, or, under `:identity`, a
  map of that identity's keys; it is looked up when its row runs.
  """
  def update_many(targets_or_sheet, resource, action, opts),
    do: start(targets_or_sheet, resource, action, :update, opts)

  @doc "Destroys each target, in `update_many/4`'s shape."
  def destroy_many(targets_or_sheet, resource, action, opts),
    do: start(targets_or_sheet, resource, action, :destroy, opts)

  @doc """
  Updates every selected record with one `input`, as `Ash.bulk_update/4`,
  stored once on the bulk action. `selection` is a query, read now as
  `:scope` so a row is what its caller could see, or a list of records or
  primary keys, each looked up when its row runs. A record's row acts in the
  record's tenant.
  """
  def bulk_update(selection, action, input, opts),
    do: start_selection(selection, action, :update, input, opts)

  @doc "Destroys every selected record, in `bulk_update/4`'s shape."
  def bulk_destroy(selection, action, input \\ %{}, opts),
    do: start_selection(selection, action, :destroy, input, opts)

  @doc """
  Reruns every row that has not succeeded, as it is or with `:input` for a
  new shared input or `:rows` for per-row corrections; see
  `AshBulkDurable.Core.Retry.retry/2`. Refused while the bulk action is
  queued or running, and a failed one while its owner has another
  unresolved one, `{:error, %{unresolved: id}}`.
  """
  defdelegate retry(bulk_action, opts), to: Core

  @doc """
  Reruns the rows that have not succeeded, with what `corrected_sheet`, an
  `errors_sheet/2` a user edited and `read_sheet/2` read, changes. Its rows
  with nothing changed rerun as they are; a row it leaves out reruns too.
  """
  def retry(bulk_action, %Sheet{} = corrected_sheet, opts) do
    with {:ok, rows} <-
           ErrorsSheet.corrections(bulk_action, corrected_sheet, Keyword.fetch!(opts, :scope)) do
      Core.retry(bulk_action, Keyword.put(opts, :rows, rows))
    end
  end

  @doc """
  Reruns one failed row by itself; see
  `AshBulkDurable.Core.Retry.retry_row/2`. `:per_row` only.
  """
  defdelegate retry_row(row, opts), to: Core

  @doc """
  The rows that have not succeeded as a sheet to correct, for `retry/3`; see
  `AshBulkDurable.Sheet.ErrorsSheet.build/2`. `AshBulkDurable.Sheet.to_csv/1`
  writes it.
  """
  defdelegate errors_sheet(bulk_action, opts \\ []), to: ErrorsSheet, as: :build

  @doc """
  Abandons a bulk action that finished with failed rows; see
  `AshBulkDurable.Core.abandon/2`.
  """
  defdelegate abandon(bulk_action, opts), to: Core

  defp start(%Sheet{rows: rows}, resource, action, type, opts) do
    mapping = mapping(resource, action!(resource, action, type), opts)
    Sheet.stage(rows, mapping, opts)
  end

  defp start(inputs, resource, action, type, opts) do
    action = action!(resource, action, type)
    identity = identity(resource, opts[:identity])
    rows = Enum.map(inputs, &row(type, &1, resource, identity))
    Core.create(resource, action.name, rows, opts)
  end

  defp start_selection(selection, action, type, input, opts) do
    resource = selection_resource!(selection, opts)
    action = action!(resource, action, type)

    with {:ok, selected} <- selected(selection, resource, opts) do
      rows = Enum.map(selected, &%{target: target(&1, resource, nil)})
      Core.create(resource, action.name, rows, Keyword.put(opts, :input, input))
    end
  end

  defp selection_resource!(selection, opts) do
    opts[:resource] || own_resource(selection) ||
      raise ArgumentError, "a list of primary keys needs `:resource`"
  end

  defp own_resource(%Ash.Query{resource: resource}), do: resource
  defp own_resource([%{__struct__: resource} | _selected]), do: resource
  defp own_resource(_selection), do: nil

  # Only what a row keeps of a record is read, so a large selection stays light.
  # A stream, as a list's read action requires pagination and `page: false`
  # would be refused.
  defp selected(%Ash.Query{} = query, resource, opts) do
    tenant_attribute = Ash.Resource.Info.multitenancy_attribute(resource)

    selected =
      query
      |> Ash.Query.select(List.wrap(tenant_attribute))
      |> Ash.stream!(Keyword.take(opts, [:scope, :tenant]))
      |> Enum.to_list()

    {:ok, selected}
  rescue
    error in [
      Ash.Error.Forbidden,
      Ash.Error.Framework,
      Ash.Error.Invalid,
      Ash.Error.Invalid.NonStreamableAction,
      Ash.Error.Unknown
    ] ->
      {:error, error}
  end

  defp selected(list, _resource, _opts) when is_list(list), do: {:ok, list}

  defp selected(selection, _resource, _opts) do
    raise ArgumentError, "a selection is a query or a list, got: #{inspect(selection)}"
  end

  defp action!(resource, name, type) do
    case Ash.Resource.Info.action(resource, name) do
      %{type: ^type} = action ->
        action

      %{type: other} ->
        raise ArgumentError,
              "#{inspect(resource)}.#{name} is a #{other} action; this verb runs #{type} actions"

      nil ->
        raise ArgumentError, "#{inspect(resource)} has no action #{inspect(name)}"
    end
  end

  defp mapping(resource, action, opts) do
    mapping = Keyword.get(opts, :mapping, [])

    %Mapping{
      resource: resource,
      action: action,
      identity: identity(resource, opts[:identity]),
      columns: Map.new(mapping[:columns] || %{}),
      rel_identities: Map.new(mapping[:rel_identities] || %{}),
      tenant_mapping: mapping[:tenant_mapping]
    }
  end

  defp identity(_resource, nil), do: nil

  defp identity(resource, name) do
    Mapping.lookup_identity(resource, name) ||
      raise ArgumentError,
            "#{inspect(resource)} has no identity #{inspect(name)} that names one record"
  end

  defp row(:create, {%{tenant: tenant}, input}, _resource, _identity),
    do: %{target: %{tenant: tenant}, input: input}

  defp row(:create, input, _resource, _identity), do: %{input: input}

  defp row(_type, {target, input}, resource, identity),
    do: %{target: target(target, resource, identity), input: input}

  # A record carries its primary key and its tenant.
  defp target(%{__struct__: resource} = record, resource, _identity) do
    %{
      lookup: Map.take(record, Ash.Resource.Info.primary_key(resource)),
      tenant: tenant(record, resource)
    }
  end

  defp target(target, resource, identity), do: %{lookup: lookup(target, resource, identity)}

  # The attribute holds the tenant even of a record read across tenants; a
  # resource without one keeps the tenant it was read in on the record.
  defp tenant(record, resource) do
    case Ash.Resource.Info.multitenancy_attribute(resource) do
      nil ->
        record.__metadata__[:tenant]

      attribute ->
        {module, function, args} = Ash.Resource.Info.multitenancy_tenant_from_attribute(resource)
        apply(module, function, [Map.fetch!(record, attribute) | args])
    end
  end

  # A map under an identity is its keys; anything else is a primary key, as
  # `Ash.update_many/4` takes one.
  defp lookup(%{} = values, resource, nil),
    do: keys(values, Ash.Resource.Info.primary_key(resource))

  defp lookup(%{} = values, _resource, %{keys: keys}), do: keys(values, keys)

  defp lookup(value, _resource, %{keys: [key]}), do: %{key => value}

  defp lookup(value, resource, nil) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] -> %{key => value}
      keys -> raise ArgumentError, "a composite primary key #{inspect(keys)} needs a map"
    end
  end

  # Every key the record is found by, whether the caller wrote it as an atom
  # or a string.
  defp keys(values, keys), do: Map.new(keys, &{&1, key!(values, &1)})

  defp key!(values, key) do
    with :error <- Map.fetch(values, key),
         :error <- Map.fetch(values, to_string(key)) do
      raise ArgumentError, "target #{inspect(values)} has no #{inspect(key)}"
    else
      {:ok, value} -> value
    end
  end
end
