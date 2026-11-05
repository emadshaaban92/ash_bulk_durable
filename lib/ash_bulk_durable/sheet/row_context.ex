defmodule AshBulkDurable.Sheet.RowContext do
  @moduledoc """
  Passed to `c:AshBulkDurable.Sheet.FieldHandler.input_value/3` for each
  row of a sheet.

  Pure environment — `resource` and `action` live on `AshBulkDurable.Sheet.Field`, not
  here.

  Fields:

    * `:scope` — Ash actor scope the sheet is staged or corrected as.
    * `:tenant` — the tenant the bulk action acts in (or `nil`), as
      `AshBulkDurable.Sheet.PrepareContext` has it.
    * `:row_index` — 0-based row index in the sheet. An error the
      handler returns is reported against this row.
    * `:row` — the full `%{column => raw_value}` for this row, useful
      when a handler needs to read sibling columns.
    * `:state` — whatever the handler returned from `prepare/2`. `nil` for
      handlers that don't implement `prepare/2`.
  """

  defstruct [:scope, :tenant, :row_index, :row, :state]

  @type t :: %__MODULE__{
          scope: term(),
          tenant: term() | nil,
          row_index: non_neg_integer(),
          row: %{optional(String.t()) => term()},
          state: term()
        }
end
