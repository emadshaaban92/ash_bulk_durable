defmodule AshBulkDurable.Sheet.FieldHandler do
  @moduledoc """
  Behaviour for pluggable field handlers: how a sheet's cell becomes one
  value of a row's input.

  A handler owns three concerns:

    * **claim** — `c:handles?/1` decides whether this handler is
      responsible for a given field.
    * **companion** — `c:companion_requirement/1` optionally says the field
      needs a file staged beside the sheet, what it accepts and how large.
      `nil` means none. It carries no words: the screens label it from the
      field's own label.
    * **value flow** — `c:input_value/3` turns one row's raw cell into the
      value the action receives for the field. It touches no changeset: the
      core runs the action with the row's input, as a form sends its
      params. A value the worker must resolve first (a record looked up, a
      file extracted) is an `AshBulkDurable.Core.Reference`.

  Plus two lifecycle hooks bracketing the rows when a sheet is staged:

    * `c:prepare/2` — runs once per sheet, before any row is mapped. The
      returned `state` is threaded into every `input_value/3` call via
      `RowContext.state`.
    * `c:finish/2` — runs once after the rows are mapped, regardless of
      outcome.

  Modules can `use AshBulkDurable.Sheet.FieldHandler` to inherit no-op
  defaults for `companion_requirement/1`, `prepare/2`, `finish/2` and
  `to_cell/2` — only `handles?/1` and `input_value/3` are then required.
  """

  @doc """
  Does this handler take responsibility for the given field?

  Pattern-match on the `AshBulkDurable.Sheet.Field` struct to discriminate
  by resource, action, and/or the underlying Ash field's shape.
  """
  @callback handles?(AshBulkDurable.Sheet.Field.t()) :: boolean()

  @doc """
  The file this field needs staged beside the sheet, or `nil` if none:
  the extensions it accepts (`[".zip"]`) and its largest size in bytes.

  The sheet layer refuses to stage a bulk action whose mapped field has a
  requirement no staged file meets; the screens copy it into their upload
  for early feedback.
  """
  @callback companion_requirement(AshBulkDurable.Sheet.Field.t()) ::
              %{accept: [String.t()], max_bytes: pos_integer()} | nil

  @doc """
  Called once per sheet, before any row is mapped.

  Return `{:ok, state}` to thread the state into every `input_value/3` call
  for this field, or `{:error, term}` to refuse the sheet before anything
  is stored.
  """
  @callback prepare(AshBulkDurable.Sheet.Field.t(), AshBulkDurable.Sheet.PrepareContext.t()) ::
              {:ok, state :: term()} | {:error, term()}

  @doc """
  Called once after the rows are mapped, regardless of outcome.

  `state` is whatever `prepare/2` returned (or `nil` if the default no-op
  was used).
  """
  @callback finish(AshBulkDurable.Sheet.Field.t(), state :: term()) :: :ok

  @doc """
  Per-row workhorse: the value the action receives for the field, from the
  raw cell.

  `{:ok, value}` sends `value` under the field's input name (a
  `belongs_to`'s source attribute, otherwise the field's own name);
  `:skip` sends nothing, leaving the field as the action would; an
  `{:error, error}` stores the row failed with that error, never run. A
  value may be an `AshBulkDurable.Core.Reference`, which the worker
  resolves before the row's transaction opens.

  A corrected cell is mapped again, and a value equal to the one the row had
  keeps what it resolved to, so the answer must depend on the raw value and
  the context only.
  """
  @callback input_value(
              AshBulkDurable.Sheet.Field.t(),
              raw_value :: term(),
              AshBulkDurable.Sheet.RowContext.t()
            ) :: {:ok, term()} | :skip | {:error, term()}

  @doc """
  The reverse of `c:input_value/3`, for the errors sheet: the cell that reads
  as `value`, the input a row holds, whichever caller gave it. A field taking
  a composite identity gives `%{key => cell}`.

  The default suits a value that is its own cell (`cell/1`). A handler whose
  `input_value/3` makes a reference overrides it, or the sheet shows
  nothing a user could correct.
  """
  @callback to_cell(AshBulkDurable.Sheet.Field.t(), value :: term()) ::
              String.t() | %{atom() => String.t()}

  @doc "`value` as a cell: `nil` is blank, a list joins on `|`, anything else reads as a string."
  def cell(nil), do: ""
  def cell(list) when is_list(list), do: Enum.map_join(list, "|", &cell/1)

  def cell(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _printable -> value |> to_string() |> String.trim()
    end
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour AshBulkDurable.Sheet.FieldHandler

      @impl AshBulkDurable.Sheet.FieldHandler
      def companion_requirement(_field), do: nil

      @impl AshBulkDurable.Sheet.FieldHandler
      def prepare(_field, _ctx), do: {:ok, nil}

      @impl AshBulkDurable.Sheet.FieldHandler
      def finish(_field, _state), do: :ok

      @impl AshBulkDurable.Sheet.FieldHandler
      def to_cell(_field, value), do: AshBulkDurable.Sheet.FieldHandler.cell(value)

      defoverridable companion_requirement: 1, prepare: 2, finish: 2, to_cell: 2
    end
  end
end
