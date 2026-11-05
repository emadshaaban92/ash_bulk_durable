defmodule AshBulkDurable.Core.Reference do
  @moduledoc """
  An input value the worker resolves before the row is written, outside its
  transaction:

    * `{:lookup, resource, identity, values}`, or with options
      `{:lookup, resource, identity, values, opts}`: the primary key of the
      `resource` record whose `identity` matches `values`, read as the actor.
      `values` is the identity's one value, or a map of its keys' values, a
      `nil` matching a null column. `opts[:filter]` is an expression the
      record must also match (a relationship's own filter). No match is
      `{:error, :not_found}`.
    * `{:resolve, module, args}`: whatever `module`, an
      `AshBulkDurable.Core.Resolver`, resolves `args` to.

  `prepare/2` readies a set of references together, so a resolver opens
  what it needs once for all of them; `finish/1` releases it.
  """

  alias AshBulkDurable.Core.Resolver.Context

  @doc "Whether `value` is a reference."
  def reference?({:lookup, resource, _identity, _values}) when is_atom(resource), do: true

  def reference?({:lookup, resource, _identity, _values, opts})
      when is_atom(resource) and is_list(opts),
      do: true

  def reference?({:resolve, module, _args}) when is_atom(module), do: true
  def reference?(_value), do: false

  @doc """
  Prepares every resolver `references` name, once each. On an error, the
  resolvers already prepared come back with it, for `finish/1`.
  """
  def prepare(references, %Context{} = context) do
    references
    |> Enum.flat_map(fn
      {:resolve, module, args} -> [{module, args}]
      _lookup -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce_while({:ok, %{}}, fn {module, args}, {:ok, prepared} ->
      case module.prepare(args, context) do
        {:ok, state} -> {:cont, {:ok, Map.put(prepared, module, state)}}
        {:error, error} -> {:halt, {:error, error, prepared}}
      end
    end)
  end

  @doc "The value `reference` resolves to, its resolver prepared in `prepared`."
  def resolve({:lookup, resource, identity, values}, prepared, context),
    do: resolve({:lookup, resource, identity, values, []}, prepared, context)

  def resolve({:lookup, resource, identity, values, opts}, _prepared, %Context{} = context) do
    read_action = Ash.Resource.Info.primary_action!(resource, :read).name

    resource
    |> Ash.Query.for_read(read_action, %{}, scope: context.scope, tenant: context.tenant)
    |> Ash.Query.filter_input(identity_filter(resource, identity, values))
    |> filter(opts[:filter])
    |> Ash.Query.limit(1)
    |> Ash.read_one(scope: context.scope, tenant: context.tenant)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, record} -> {:ok, primary_key(resource, record)}
      {:error, error} -> {:error, error}
    end
  end

  def resolve({:resolve, module, args}, prepared, %Context{} = context),
    do: module.resolve(args, Map.fetch!(prepared, module), context)

  @doc "Releases every prepared resolver."
  def finish(prepared), do: Enum.each(prepared, fn {module, state} -> module.finish(state) end)

  @doc """
  Hands `record`, once written with `resolved`, to the reference's resolver
  when it asks for it.
  """
  def after_write({:resolve, module, _args}, record, resolved, %Context{} = context) do
    if function_exported?(module, :after_write, 3),
      do: module.after_write(record, resolved, context),
      else: :ok
  end

  def after_write(_lookup, _record, _resolved, _context), do: :ok

  @doc "Those of `resolved`, values of `module`, it says can no longer be used."
  def lost(module, resolved, %Context{} = context) do
    if Code.ensure_loaded?(module) and function_exported?(module, :lost, 2),
      do: module.lost(resolved, context),
      else: []
  end

  @doc "`value` names a composite identity's keys. A struct is one value."
  defguard is_composite(value) when is_map(value) and not is_struct(value)

  @doc "Whether `value` is a reference only a resolver can answer."
  def resolver?({:resolve, _module, _args}), do: true
  def resolver?(_value), do: false

  # A composite identity's values name their keys; a single value is matched
  # on the identity's one key. A nil is an explicit `is_nil`, since
  # `column = NULL` is never true.
  defp identity_filter(_resource, _identity, values) when is_composite(values),
    do: Map.new(values, &filter_entry/1)

  defp identity_filter(resource, identity, value),
    do: Map.new([{identity_key(resource, identity), value}], &filter_entry/1)

  defp identity_key(resource, identity) do
    case Ash.Resource.Info.identity(resource, identity) do
      %{keys: [key]} -> key
      _none -> identity
    end
  end

  defp filter_entry({key, nil}), do: {key, %{is_nil: true}}
  defp filter_entry({key, value}), do: {key, value}

  defp filter(query, nil), do: query
  defp filter(query, expression), do: Ash.Query.do_filter(query, expression)

  defp primary_key(resource, record) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] -> Map.fetch!(record, key)
      keys -> Map.take(record, keys)
    end
  end
end
