defmodule AshBulkDurable.Sheet.FieldHandlers.Scalar do
  @moduledoc """
  Default handler for action arguments and attributes whose value can come
  straight from a CSV cell.

  Claim policy:

    * Built-in Ash primitive types (`:string`, `:integer`, `:boolean`,
      `:decimal`, `:date`, `:datetime`, `:atom`, `:uuid`, …).
    * `{:array, T}` where `T` is one of those primitives.
    * Any `Ash.Type.NewType` chain wrapping the above (e.g. a custom
      `:string`-backed newtype).
    * Any module implementing `Ash.Type.Enum`.

  Not claimed (other handlers can take these):

    * `Ash.Resource.Relationships.BelongsTo` — `AshBulkDurable.Sheet.FieldHandlers.BelongsTo`.
    * Embedded resources (`Ash.Resource.Info.embedded?/1`) and arbitrary
      custom `Ash.Type` modules (e.g. attachment types) — apps prepend
      their own handler.

  Value flow:

    * `{:array, _}` types: pipe-delimited CSV cells are split on `|`,
      trimmed, with empty entries dropped, before being handed to Ash.
    * Anything else: the raw value is forwarded as-is — Ash casts it.

  No companion upload, no per-submit lifecycle.
  """

  use AshBulkDurable.Sheet.FieldHandler

  # Ash builtins that are reasonably mappable from a single CSV cell.
  # Stored as full module names because that's the shape an Attribute /
  # Argument struct carries — short-name atoms like `:string` are normalised
  # via `Ash.Type.get_type/1` before the check.
  @primitive_modules [
    Ash.Type.Atom,
    Ash.Type.Binary,
    Ash.Type.Boolean,
    Ash.Type.CiString,
    Ash.Type.Date,
    Ash.Type.DateTime,
    Ash.Type.Decimal,
    Ash.Type.Duration,
    Ash.Type.DurationName,
    Ash.Type.Float,
    Ash.Type.Integer,
    Ash.Type.NaiveDatetime,
    Ash.Type.String,
    Ash.Type.Time,
    Ash.Type.TimeUsec,
    Ash.Type.UrlEncodedBinary,
    Ash.Type.UtcDatetime,
    Ash.Type.UtcDatetimeUsec,
    Ash.Type.UUID,
    Ash.Type.UUIDv7
  ]

  @impl AshBulkDurable.Sheet.FieldHandler
  def handles?(%AshBulkDurable.Sheet.Field{field: %Ash.Resource.Relationships.BelongsTo{}}),
    do: false

  def handles?(%AshBulkDurable.Sheet.Field{field: %_{type: type}}), do: scalar_type?(type)

  def handles?(%AshBulkDurable.Sheet.Field{}), do: false

  @impl AshBulkDurable.Sheet.FieldHandler
  def input_value(%AshBulkDurable.Sheet.Field{field: field}, raw_value, _ctx),
    do: {:ok, maybe_split_array(field.type, raw_value)}

  defp maybe_split_array({:array, _inner}, value) when is_binary(value) do
    value
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_split_array(_type, value), do: value

  defp scalar_type?(type) do
    case type |> unwrap_new_type() |> Ash.Type.get_type() do
      {:array, inner} -> primitive?(inner)
      other -> primitive?(other)
    end
  end

  defp primitive?(type) when type in @primitive_modules, do: true
  defp primitive?(type) when is_atom(type), do: enum?(type)
  defp primitive?(_), do: false

  defp enum?(type) do
    Code.ensure_loaded?(type) and Spark.implements_behaviour?(type, Ash.Type.Enum)
  end

  defp unwrap_new_type(type) do
    if Ash.Type.NewType.new_type?(type) do
      Ash.Type.NewType.subtype_of(type)
    else
      type
    end
  end
end
