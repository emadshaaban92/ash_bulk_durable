defmodule AshBulkDurable.Sheet.FieldHandlers.BelongsTo do
  @moduledoc """
  Default handler for `belongs_to` relationships.

  Claim policy: any field whose underlying Ash struct is
  `Ash.Resource.Relationships.BelongsTo`.

  Value flow: the CSV value is treated as a *key*, not an id — looked up
  against the related resource using a user-chosen identity. That identity
  is the mapping's `rel_identities` entry for the field (the screens'
  "Lookup by" dropdown), which `AshBulkDurable.Sheet.Mapping` hands the
  handler as its state instead of calling `prepare/2`, and reaches it
  through `RowContext.state[:identity]`. With no
  identity, or no value to look up, the handler sends nothing.

  The value is a `{:lookup, ...}` reference the worker resolves to the
  related record's primary key, honouring the relationship's own `filter`
  (e.g. a self-referential `parent` that restricts which rows can be
  parents), and sends as the relationship's source attribute. A miss fails
  the row naming the related resource and the criteria; a read the actor
  is refused fails it with the refusal.

  No companion upload, no per-submit lifecycle.
  """

  use AshBulkDurable.Sheet.FieldHandler

  import AshBulkDurable.Core.Reference, only: [is_composite: 1]

  alias AshBulkDurable.Sheet.FieldHandler

  @impl AshBulkDurable.Sheet.FieldHandler
  def handles?(%AshBulkDurable.Sheet.Field{field: %Ash.Resource.Relationships.BelongsTo{}}),
    do: true

  def handles?(%AshBulkDurable.Sheet.Field{}), do: false

  @impl AshBulkDurable.Sheet.FieldHandler
  def input_value(%AshBulkDurable.Sheet.Field{field: relationship}, raw_value, ctx) do
    case {identity_from(ctx), raw_value} do
      {nil, _value} -> :skip
      {_identity, nil} -> :skip
      {_identity, ""} -> :skip
      {_identity, %{} = composite} when map_size(composite) == 0 -> :skip
      {identity, value} -> {:ok, lookup(relationship, identity, value)}
    end
  end

  @impl AshBulkDurable.Sheet.FieldHandler
  def to_cell(_field, {:lookup, _resource, _identity, values}), do: lookup_cell(values)
  def to_cell(_field, {:lookup, _resource, _identity, values, _opts}), do: lookup_cell(values)
  def to_cell(_field, value), do: FieldHandler.cell(value)

  defp lookup_cell(values) when is_composite(values),
    do: Map.new(values, fn {k, v} -> {k, FieldHandler.cell(v)} end)

  defp lookup_cell(value), do: FieldHandler.cell(value)

  defp lookup(%{destination: destination, filter: nil}, identity, value),
    do: {:lookup, destination, identity, value}

  defp lookup(%{destination: destination, filter: filter}, identity, value),
    do: {:lookup, destination, identity, value, filter: filter}

  defp identity_from(%AshBulkDurable.Sheet.RowContext{state: %{identity: identity}})
       when is_atom(identity) and not is_nil(identity),
       do: identity

  defp identity_from(_), do: nil
end
