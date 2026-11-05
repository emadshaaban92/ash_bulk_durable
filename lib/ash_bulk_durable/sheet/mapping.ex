defmodule AshBulkDurable.Sheet.Mapping do
  @moduledoc """
  How a sheet's columns feed one action, and the rows it makes of a sheet.

    * `resource`, `action` — what runs.
    * `identity` — what an update's or destroy's row finds its record by,
      one of `lookup_identities/1`; `nil` for a create.
    * `columns` — `%{field_name => column}`, or `%{field_name => %{key =>
      column}}` for a relationship looked up by a composite identity.
    * `rel_identities` — `%{relationship_name => identity_name}`: the
      identity a relationship's cell is looked up by.
    * `tenant_mapping` — the column saying whose a row is, or `nil`.
      `%{resource:, identity:, csv_col:}` names the row's tenant, on a
      resource with Ash multitenancy: the cell is looked up in `resource`,
      and a cell finding nothing, a blank one too, fails its row rather than
      running in the bulk action's tenant.
      `%{rel_name:, identity:, csv_col:}` names no tenant: it narrows the
      record's lookup through the relationship `rel_name` (the lookup gains
      `%{rel_name => %{identity => cell}}`).

  `rows/3` maps each sheet row to a core row: the target its identity
  columns look up, the input its other mapped columns give through their
  field handlers, and the sheet row itself as the row's metadata. The
  mapping is kept on the bulk action as its metadata (`to_metadata/1`,
  `from_bulk_action/1`), so an errors sheet looks a corrected cell up the
  same way (`AshBulkDurable.Sheet.ErrorsSheet`).
  """

  alias AshBulkDurable.Core.Introspection
  alias AshBulkDurable.Sheet
  alias AshBulkDurable.Sheet.{Field, FieldHandlers, PrepareContext, RowContext}

  @enforce_keys [:resource, :action]
  defstruct [:resource, :action, :identity, :tenant_mapping, columns: %{}, rel_identities: %{}]

  @doc """
  The handler-claimed, mapped `Field` structs: exactly the fields a row's
  target and input are built from.
  """
  def fields(%__MODULE__{} = mapping) do
    resource = mapping.resource
    action = mapping.action
    relationships = Ash.Resource.Info.relationships(resource)

    mapping
    |> identity_keys()
    |> Enum.concat(Ash.Resource.Info.action_inputs(resource, action.name))
    |> Enum.filter(&is_atom/1)
    |> Enum.reject(&(&1 |> to_string() |> String.ends_with?("_ids")))
    |> Enum.uniq()
    |> Enum.map(fn name ->
      Enum.find(relationships, &relationship_of?(&1, name, mapping)) ||
        Enum.find(action.arguments, &(&1.name == name)) ||
        Ash.Resource.Info.attribute(resource, name) || name
    end)
    |> Enum.map(&%Field{field: &1, resource: resource, action: action})
    |> Enum.filter(fn %Field{field: f} = field ->
      Map.has_key?(mapping.columns, f.name) and Sheet.handler_for(field) != nil
    end)
  end

  # A `belongs_to` whose key is mapped itself is that key, as a form sends it.
  defp relationship_of?(relationship, name, mapping) do
    relationship.source_attribute == name and Map.has_key?(mapping.columns, relationship.name)
  end

  defp identity_keys(%{identity: nil}), do: []
  defp identity_keys(%{identity: %{keys: keys}}), do: keys

  @doc """
  The core rows `sheet_rows` make: `{:ok, [%{target:, input:, metadata:,
  error:}]}`, a row whose cell a handler refused carrying that error, or
  `{:error, term}` when a handler's `prepare/2` refuses the sheet. `context`
  is what the handlers are prepared with, and each row's context takes its
  scope and tenant from it.
  """
  def rows(%__MODULE__{} = mapping, sheet_rows, %PrepareContext{} = context) do
    with {:ok, prepared} <- prepare(mapping, context) do
      try do
        {:ok,
         sheet_rows
         |> Enum.with_index()
         |> Enum.map(fn {sheet_row, index} ->
           row(mapping, prepared, context, sheet_row, index)
         end)}
      after
        finish(prepared)
      end
    end
  end

  @doc """
  What a sheet's row can find its record by: the primary key, as
  `:primary_key`, and every identity but a partial one, whose keys alone
  match the records its `where` leaves out too.
  """
  def lookup_identities(resource) do
    identities = Enum.filter(Ash.Resource.Info.identities(resource), &is_nil(&1.where))

    case Ash.Resource.Info.primary_key(resource) do
      [] ->
        identities

      keys ->
        [%Ash.Resource.Identity{name: :primary_key, keys: keys, all_tenants?: true} | identities]
    end
  end

  @doc "The one of `lookup_identities/1` called `name`, or `nil`."
  def lookup_identity(resource, name),
    do: resource |> lookup_identities() |> Enum.find(&(&1.name == name))

  @doc """
  Raises unless `mapping` can say which record a row means: every action but
  a create finds its record by an identity, a lookup with no keys would match
  whatever the actor can read, and a partial identity's keys can match several.
  """
  def identified!(%__MODULE__{action: %{type: :create}}), do: :ok

  def identified!(%__MODULE__{identity: nil, resource: resource, action: action}) do
    raise ArgumentError,
          "#{inspect(resource)}.#{action.name} from a sheet needs an :identity to find each row's record"
  end

  def identified!(%__MODULE__{identity: %{where: where} = identity, resource: resource})
      when not is_nil(where) do
    raise ArgumentError,
          "#{inspect(identity.name)} on #{inspect(resource)} is a partial identity, so its keys don't name one record"
  end

  def identified!(%__MODULE__{}), do: :ok

  @doc "The core row one sheet row makes; see `rows/3`."
  def row(%__MODULE__{} = mapping, prepared, context, sheet_row, index) do
    {input, errors} = row_input(mapping, prepared, context, sheet_row, index)

    %{
      target: target(mapping, sheet_row),
      input: input,
      metadata: sheet_row,
      error: if(errors == [], do: nil, else: Enum.reverse(errors))
    }
  end

  @doc "Finishes what `prepare/2` prepared."
  def finish(prepared),
    do: Enum.each(prepared, fn {field, handler, state} -> handler.finish(field, state) end)

  @doc """
  Each mapped field with its handler and the state its `prepare/2` gave:
  `{:ok, [{field, handler, state}]}`, or `{:error, term}` once a handler
  refuses, the ones already prepared finished.
  """
  def prepare(%__MODULE__{} = mapping, %PrepareContext{} = context) do
    mapping
    |> fields()
    |> Enum.reduce_while({:ok, []}, &prepare_one(mapping, &1, context, &2))
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepare_one(mapping, field, context, {:ok, prepared}) do
    handler = Sheet.handler_for(field)

    case prepare_field(mapping, handler, field, context) do
      {:ok, state} ->
        {:cont, {:ok, [{field, handler, state} | prepared]}}

      {:error, term} ->
        finish(prepared)
        {:halt, {:error, term}}
    end
  end

  # The identity a `belongs_to` cell is looked up by is the mapping's.
  defp prepare_field(mapping, FieldHandlers.BelongsTo, field, _context),
    do: {:ok, %{identity: Map.get(mapping.rel_identities, field.field.name)}}

  defp prepare_field(_mapping, handler, field, context), do: handler.prepare(field, context)

  # A destroy's mapped columns only find its record.
  defp row_input(%{action: %{type: :destroy}}, _prepared, _context, _sheet_row, _index),
    do: {%{}, []}

  defp row_input(mapping, prepared, context, sheet_row, index),
    do: input(mapping, prepared, context, sheet_row, index)

  @doc """
  The input the `prepared` fields give for one sheet row: `{input, errors}`,
  the newest error first.
  """
  def input(mapping, prepared, %PrepareContext{} = prepare_context, sheet_row, index) do
    inputs = Ash.Resource.Info.action_inputs(mapping.resource, mapping.action.name)

    context = %RowContext{
      scope: prepare_context.scope,
      tenant: prepare_context.tenant,
      row_index: index,
      row: sheet_row
    }

    prepared
    # A key the action doesn't take (an update's identity) only finds the record.
    |> Enum.filter(fn {field, _handler, _state} -> MapSet.member?(inputs, input_key(field)) end)
    |> Enum.reduce({%{}, []}, fn {field, handler, state}, {input, errors} ->
      cell = cell(Map.fetch!(mapping.columns, field.field.name), sheet_row)

      case handler.input_value(field, cell, %{context | state: state}) do
        {:ok, value} -> {Map.put(input, input_key(field), value), errors}
        :skip -> {input, errors}
        {:error, error} -> {input, [error | errors]}
      end
    end)
  end

  @doc """
  The input `field` feeds. A `belongs_to` is sent as its source attribute, as
  a form sends it.
  """
  def input_key(%Field{field: %Ash.Resource.Relationships.BelongsTo{source_attribute: key}}),
    do: key

  def input_key(%Field{field: %{name: name}}), do: name

  defp target(%{action: %{type: :create}, tenant_mapping: %{resource: _} = tenant}, sheet_row),
    do: named_tenant(%{}, tenant, sheet_row)

  defp target(%{action: %{type: :create}}, _sheet_row), do: nil

  defp target(mapping, sheet_row) do
    lookup =
      Map.new(identity_keys(mapping), fn key ->
        {key, sheet_row[Map.get(mapping.columns, key)]}
      end)

    mapping.identity
    |> found_by(%{lookup: narrow(lookup, mapping.tenant_mapping, sheet_row)})
    |> named_tenant(mapping.tenant_mapping, sheet_row)
  end

  # A primary key typed into a sheet can be mistyped, so it stays correctable
  # where a selection's cannot.
  defp found_by(%{name: :primary_key}, target), do: Map.put(target, :identity, :primary_key)
  defp found_by(_identity, target), do: target

  defp narrow(lookup, %{rel_name: rel, identity: identity, csv_col: column}, sheet_row),
    do: Map.put(lookup, rel, %{identity => sheet_row[column]})

  defp narrow(lookup, _tenant_mapping, _sheet_row), do: lookup

  defp named_tenant(
         target,
         %{resource: resource, identity: identity, csv_col: column},
         sheet_row
       ),
       do: Map.put(target, :tenant, {:lookup, resource, identity, sheet_row[column]})

  defp named_tenant(target, _tenant_mapping, _sheet_row), do: target

  # A composite identity's columns give a map of its keys' cells, a blank
  # one nil so it matches a null column.
  defp cell(%{} = columns, sheet_row) do
    Map.new(columns, fn {key, column} -> {key, blank_to_nil(sheet_row[column])} end)
  end

  defp cell(column, sheet_row), do: sheet_row[column]

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # ── Kept on the bulk action ──────────────────────────────────────────────

  @doc "The mapping as the bulk action keeps it, JSON-safe."
  def to_metadata(%__MODULE__{} = mapping) do
    %{
      "identity" => mapping.identity && to_string(mapping.identity.name),
      "columns" => stringify(mapping.columns),
      "rel_identities" => stringify(mapping.rel_identities),
      "tenant_mapping" => mapping.tenant_mapping && stringify(mapping.tenant_mapping)
    }
  end

  @doc "The mapping `bulk_action` was staged with, from its metadata."
  def from_bulk_action(bulk_action) do
    resource = Introspection.resource(bulk_action)
    metadata = bulk_action.metadata || %{}

    %__MODULE__{
      resource: resource,
      action: Introspection.action(bulk_action),
      identity: identity(resource, fetch(metadata, "identity")),
      columns: columns(fetch(metadata, "columns") || %{}),
      rel_identities: rel_identities(fetch(metadata, "rel_identities") || %{}),
      tenant_mapping: tenant_mapping(fetch(metadata, "tenant_mapping"))
    }
  end

  defp identity(_resource, nil), do: nil

  defp identity(resource, name), do: lookup_identity(resource, Introspection.normalize_atom(name))

  defp columns(columns) do
    Map.new(columns, fn
      {field, %{} = composite} ->
        {atom(field), Map.new(composite, fn {key, column} -> {atom(key), column} end)}

      {field, column} ->
        {atom(field), column}
    end)
  end

  defp rel_identities(rel_identities),
    do: Map.new(rel_identities, fn {field, identity} -> {atom(field), atom(identity)} end)

  defp tenant_mapping(nil), do: nil

  defp tenant_mapping(%{"resource" => resource} = tenant_mapping) do
    %{
      resource: atom(resource),
      identity: atom(fetch(tenant_mapping, "identity")),
      csv_col: fetch(tenant_mapping, "csv_col")
    }
  end

  defp tenant_mapping(%{} = tenant_mapping) do
    %{
      rel_name: atom(fetch(tenant_mapping, "rel_name")),
      identity: atom(fetch(tenant_mapping, "identity")),
      csv_col: fetch(tenant_mapping, "csv_col")
    }
  end

  defp fetch(map, key), do: Map.get(map, key)

  defp atom(value), do: Introspection.normalize_atom(value)

  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: to_string(value)

  defp stringify(value), do: value
end
