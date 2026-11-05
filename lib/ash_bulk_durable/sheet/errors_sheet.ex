defmodule AshBulkDurable.Sheet.ErrorsSheet do
  @moduledoc """
  The rows of a bulk action that have not succeeded, as a sheet to correct
  and upload again, whatever the bulk action started from. Shaped by the
  action, not by any original file: `row_id`, `last_error`, then one column
  per input a field handler claims, named for the input. A relationship
  looked up by a composite identity takes a column per key (`owner_id.code`),
  and a row found by an identity shows its lookup the same way, a key the
  action also takes sharing that input's column. A row naming its tenant by a
  lookup shows it under `tenant.<identity>`.

  A cell reads back only where it differs from what the sheet showed, so an
  input a row never had stays unsent however blank its cell, and a row with
  nothing changed reruns as it is. A changed cell goes through its field's
  handler, as a cell of any sheet does; a column the sheet no longer has
  changes nothing.

  A cell a handler refused reached no input, so a refused row shows it from
  the sheet it came from, or from what was typed when a correction was the
  one refused, and always reads it back: whatever else a correction changes,
  the row reopens only once that cell gets past its handler.
  """

  import AshBulkDurable.Core.Reference, only: [is_composite: 1]

  alias AshBulkDurable.{Core, Sheet}
  alias AshBulkDurable.Core.{Introspection, Reference, Runner}
  alias AshBulkDurable.Sheet.{Mapping, PrepareContext}

  @row_id "row_id"
  @error "last_error"

  @doc """
  The errors sheet of `bulk_action`, a `%AshBulkDurable.Sheet{}`.

  `:error` words a row's stored errors for its `last_error` cell; by default
  each reads as the message stored with it. An all-or-nothing failure rolled
  its row back, so that row shows the bulk action's error.
  """
  def build(bulk_action, opts \\ []) do
    rows = Core.open_rows(bulk_action)
    readable!([bulk_action | rows])
    mapping = mapping(bulk_action, rows)
    word = Keyword.get(opts, :error, &messages/1)
    sheet_rows = Enum.map(rows, &{&1, cells(mapping, bulk_action, &1)})

    %Sheet{
      headers: [@row_id, @error | columns(mapping, sheet_rows)],
      rows:
        Enum.map(sheet_rows, fn {row, cells} ->
          Map.merge(cells, %{@row_id => row.id, @error => word.(error(bulk_action, row))})
        end)
    }
  end

  defp readable!(records) do
    with {:error, :gone} <- Introspection.readable(records) do
      raise ArgumentError, "a row stored what no longer decodes, so it has no cells to show"
    end
  end

  @doc "`row`'s cells that hold something, `%{column => cell}`."
  def cells(bulk_action, row), do: cells(mapping(bulk_action, [row]), bulk_action, row)

  @doc """
  What `sheet`, a corrected errors sheet, changes: `{:ok, %{row_id =>
  correction}}` for `AshBulkDurable.Core.retry/2`'s `:rows`, a row with
  nothing changed having an empty one, `{:error, :gone}` when the bulk
  action's resource or action no longer exists, or `{:error, term}` when a
  handler's `prepare/2` refuses it. Handlers read it in the bulk action's
  tenant, the one its rows run in, as `scope`.
  """
  def corrections(bulk_action, %Sheet{rows: sheet_rows}, scope) do
    with :ok <- Introspection.runnable(bulk_action),
         rows = Core.open_rows(bulk_action),
         mapping = mapping(bulk_action, rows),
         context = %PrepareContext{scope: scope, tenant: bulk_action.tenant},
         {:ok, prepared} <- Mapping.prepare(mapping, context) do
      by_id = Map.new(rows, &{&1.id, &1})

      try do
        {:ok,
         Map.new(sheet_rows, fn sheet_row ->
           row = Map.get(by_id, sheet_row[@row_id])
           correction = correction(row, mapping, prepared, bulk_action, sheet_row, context)
           {sheet_row[@row_id], correction}
         end)}
      after
        Mapping.finish(prepared)
      end
    end
  end

  # ── Reading a corrected row back ─────────────────────────────────────────

  defp correction(nil, _mapping, _prepared, _bulk_action, _sheet_row, _context), do: %{}

  defp correction(row, mapping, prepared, bulk_action, sheet_row, context) do
    shown = cells(mapping, bulk_action, row)
    sheet_row = Map.merge(shown, sheet_row)

    %{}
    |> put_input(row, mapping, prepared, bulk_action, {sheet_row, shown}, context)
    |> put_lookup(row, mapping, {sheet_row, shown})
    |> put_tenant(row, {sheet_row, shown})
  end

  defp put_input(correction, row, mapping, prepared, bulk_action, {sheet_row, shown}, context) do
    held = refused_inputs(row, bulk_action, mapping)

    case Enum.filter(prepared, &read_back?(&1, held, mapping, sheet_row, shown)) do
      [] ->
        correction

      changed ->
        {input, errors} = Mapping.input(mapping, changed, context, sheet_row, row.row_index)
        left_out = Enum.reject(changed, &is_map_key(input, Mapping.input_key(elem(&1, 0))))
        typed = typed_cells(left_out, bulk_action, mapping, sheet_row)

        correction
        |> Map.put(:input, corrected_input(row, bulk_action, changed, input))
        |> put_errors(errors, row, typed)
    end
  end

  defp read_back?({field, _handler, _state} = prepared, held, mapping, sheet_row, shown),
    do: field in held or field_changed?(prepared, mapping, sheet_row, shown)

  defp put_errors(correction, [], _row, _typed), do: correction

  # What it refused this time is the cell the next sheet must show, on a row
  # refused only now as on one refused from the start.
  defp put_errors(correction, errors, row, typed) do
    correction
    |> Map.put(:error, Enum.reverse(errors))
    |> Map.put(:metadata, Map.merge(row.metadata, typed))
  end

  defp typed_cells(left_out, bulk_action, mapping, sheet_row) do
    source = source_columns(bulk_action, mapping)

    for {%{field: %{name: name}}, _handler, _state} <- left_out,
        {sheet_column, column} <- cell_columns(mapping, source, name),
        into: %{},
        do: {column, Map.get(sheet_row, sheet_column, "")}
  end

  # A `:skip` sends nothing, so what the row had under a changed field goes.
  defp corrected_input(row, bulk_action, changed, input) do
    keys = Enum.flat_map(changed, &key_forms(Mapping.input_key(elem(&1, 0))))

    row
    |> Runner.input(bulk_action.input)
    |> Map.drop(keys)
    |> Map.merge(input)
  end

  defp key_forms(key), do: [key, to_string(key)]

  defp field_changed?({field, _handler, _state}, mapping, sheet_row, shown) do
    mapping.columns
    |> Map.fetch!(field.field.name)
    |> column_names()
    |> Enum.any?(&changed?(&1, sheet_row, shown))
  end

  defp changed?(column, sheet_row, shown) do
    case Map.fetch(sheet_row, column) do
      {:ok, cell} -> cell != Map.get(shown, column, "")
      :error -> false
    end
  end

  defp put_lookup(correction, row, mapping, {sheet_row, shown}) do
    %{target: target} = row

    if Runner.found_by_identity?(target, mapping.resource) do
      case corrected_lookup(target.lookup, sheet_row, shown) do
        lookup when lookup == target.lookup -> correction
        lookup -> Map.put(correction, :lookup, lookup)
      end
    else
      correction
    end
  end

  defp put_tenant(correction, %{target: %{tenant: tenant}}, {sheet_row, shown}) do
    with {column, value} <- tenant_cell(tenant),
         corrected when corrected != value <- corrected_key(column, value, sheet_row, shown) do
      Map.put(correction, :tenant, put_elem(tenant, 3, corrected))
    else
      _unchanged -> correction
    end
  end

  defp put_tenant(correction, _row, _sheets), do: correction

  defp corrected_lookup(lookup, sheet_row, shown) do
    Map.new(lookup, fn
      {key, nested} when is_composite(nested) ->
        {key,
         Map.new(nested, fn {sub_key, value} ->
           {sub_key, corrected_key("#{key}.#{sub_key}", value, sheet_row, shown)}
         end)}

      {key, value} ->
        {key, corrected_key(to_string(key), value, sheet_row, shown)}
    end)
  end

  # A key sharing an input's column follows it only when the two agreed: an
  # update that renames a record shows the new name, not the one it looks up.
  defp corrected_key(column, value, sheet_row, shown) do
    if Map.get(shown, column) == cell(value) and changed?(column, sheet_row, shown),
      do: Map.fetch!(sheet_row, column),
      else: value
  end

  # ── Writing a row out ────────────────────────────────────────────────────

  defp columns(mapping, sheet_rows) do
    inputs =
      mapping
      |> Mapping.fields()
      |> Enum.flat_map(&column_names(Map.fetch!(mapping.columns, &1.field.name)))

    lookups = Enum.flat_map(sheet_rows, fn {_row, cells} -> Map.keys(cells) end)

    (inputs ++ lookups) |> Enum.uniq() |> Enum.sort()
  end

  defp column_names(%{} = columns), do: Map.values(columns)
  defp column_names(column), do: [column]

  defp cells(mapping, bulk_action, row) do
    input = row |> Runner.input(bulk_action.input) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    mapping
    |> Mapping.fields()
    |> Enum.reduce(lookup_cells(row.target, mapping.resource), fn field, cells ->
      case Map.fetch(input, to_string(Mapping.input_key(field))) do
        {:ok, value} -> Map.merge(cells, input_cells(mapping, field, value))
        :error -> cells
      end
    end)
    |> Map.merge(refused_cells(row, bulk_action, mapping))
  end

  # The fields a refused row has no input for and holds a cell for: from the
  # source sheet, or from a correction, in a column no source sheet need have.
  defp refused_inputs(%{refused: true} = row, bulk_action, mapping) do
    source = source_columns(bulk_action, mapping)
    input = row |> Runner.input(bulk_action.input) |> Map.keys() |> Enum.map(&to_string/1)

    mapping
    |> Mapping.fields()
    |> Enum.reject(&(to_string(Mapping.input_key(&1)) in input))
    |> Enum.filter(fn %{field: %{name: name}} ->
      mapping
      |> cell_columns(source, name)
      |> Enum.any?(fn {_sheet_column, column} -> is_map_key(row.metadata, column) end)
    end)
  end

  defp refused_inputs(_row, _bulk_action, _mapping), do: []

  # `{errors sheet column, column of the sheet the row came from}`.
  defp refused_columns(row, bulk_action, mapping) do
    source = source_columns(bulk_action, mapping)

    Enum.flat_map(refused_inputs(row, bulk_action, mapping), fn %{field: %{name: name}} ->
      cell_columns(mapping, source, name)
    end)
  end

  # Where a row's metadata keeps each field's cell: under the source sheet's
  # column, or the errors sheet's own where no source sheet mapped it.
  defp source_columns(bulk_action, mapping),
    do: Map.merge(mapping.columns, Mapping.from_bulk_action(bulk_action).columns)

  defp cell_columns(mapping, source, name),
    do: column_pairs(Map.fetch!(mapping.columns, name), Map.fetch!(source, name))

  defp column_pairs(%{} = sheet_columns, %{} = columns) do
    for {key, column} <- columns, is_map_key(sheet_columns, key) do
      {Map.fetch!(sheet_columns, key), column}
    end
  end

  defp column_pairs(sheet_column, column) when is_binary(sheet_column) and is_binary(column),
    do: [{sheet_column, column}]

  defp column_pairs(_sheet_column, _column), do: []

  defp refused_cells(row, bulk_action, mapping) do
    for {sheet_column, column} <- refused_columns(row, bulk_action, mapping),
        cell = Map.get(row.metadata, column, ""),
        cell != "",
        into: %{},
        do: {sheet_column, cell}
  end

  defp input_cells(mapping, field, value) do
    columns = Map.fetch!(mapping.columns, field.field.name)

    case {columns, Sheet.handler_for(field).to_cell(field, value)} do
      {%{} = columns, %{} = cells} ->
        for {key, cell} <- cells, cell != "", into: %{}, do: {Map.fetch!(columns, key), cell}

      # No key to file a value under that names no lookup. The cell reads back
      # as unchanged, so the row keeps the value.
      {%{}, _plain} ->
        %{}

      {_column, ""} ->
        %{}

      {column, cell} ->
        %{column => cell}
    end
  end

  defp lookup_cells(target, resource) do
    if Runner.found_by_identity?(target, resource) do
      target.lookup |> Enum.flat_map(&lookup_cell/1) |> Map.new()
    else
      %{}
    end
    |> Map.merge(tenant_cells(target))
  end

  defp tenant_cells(%{tenant: tenant}) do
    case tenant_cell(tenant) do
      {column, value} -> %{column => cell(value)}
      nil -> %{}
    end
  end

  defp tenant_cells(_target), do: %{}

  # A tenant named by one key: `nil` for a value, which has no cell to correct.
  defp tenant_cell({:lookup, _resource, identity, value}) when not is_composite(value),
    do: {"tenant.#{identity}", value}

  defp tenant_cell({:lookup, _resource, identity, value, _opts}) when not is_composite(value),
    do: {"tenant.#{identity}", value}

  defp tenant_cell(_tenant), do: nil

  defp lookup_cell({key, nested}) when is_composite(nested),
    do: Enum.map(nested, fn {sub_key, value} -> {"#{key}.#{sub_key}", cell(value)} end)

  defp lookup_cell({key, value}), do: [{to_string(key), cell(value)}]

  defp cell(value), do: Sheet.FieldHandler.cell(value)

  defp error(%{result: %{"row_index" => index}} = bulk_action, %{row_index: index, error: nil}),
    do: bulk_action.error

  defp error(_bulk_action, row), do: row.error

  defp messages(nil), do: ""
  defp messages(stored), do: Enum.map_join(stored, "; ", & &1.message)

  # ── The mapping an errors sheet reads with ───────────────────────────────

  # Every input its own column. A `belongs_to` reads as its relationship
  # where the identity it was looked up by is known, from the sheet the bulk
  # action started from or the references its rows hold, and otherwise as the
  # plain key it was given.
  defp mapping(bulk_action, rows) do
    stored = Mapping.from_bulk_action(bulk_action)
    rel_identities = Map.merge(stored.rel_identities, referenced(stored, bulk_action, rows))

    %{
      stored
      | identity: nil,
        rel_identities: rel_identities,
        columns: input_columns(stored, rel_identities)
    }
  end

  defp referenced(mapping, bulk_action, rows) do
    for row <- rows,
        {key, value} <- Runner.input(row, bulk_action.input),
        Reference.reference?(value),
        relationship = belongs_to(mapping.resource, key),
        relationship != nil,
        identity = identity_of(value),
        into: %{},
        do: {relationship.name, identity}
  end

  defp identity_of({:lookup, _resource, identity, _values}), do: identity
  defp identity_of({:lookup, _resource, identity, _values, _opts}), do: identity
  defp identity_of(_reference), do: nil

  defp input_columns(%{resource: resource, action: action}, rel_identities) do
    resource
    |> Ash.Resource.Info.action_inputs(action.name)
    |> Enum.filter(&is_atom/1)
    |> Map.new(fn name ->
      relationship = belongs_to(resource, name)

      case relationship && Map.get(rel_identities, relationship.name) do
        nil -> {name, to_string(name)}
        identity -> {relationship.name, relationship_columns(name, relationship, identity)}
      end
    end)
  end

  defp relationship_columns(name, relationship, identity) do
    case Ash.Resource.Info.identity(relationship.destination, identity) do
      %{keys: [_key, _other | _keys] = keys} -> Map.new(keys, &{&1, "#{name}.#{&1}"})
      _single -> to_string(name)
    end
  end

  defp belongs_to(resource, key) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and to_string(&1.source_attribute) == to_string(key)))
  end
end
