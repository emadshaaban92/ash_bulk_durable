defmodule AshBulkDurable.Sheet.PrepareContext do
  @moduledoc """
  Passed once to `c:AshBulkDurable.Sheet.FieldHandler.prepare/2` before any
  row of a sheet is mapped.

  Pure environment — `resource` and `action` live on
  `AshBulkDurable.Sheet.Field`, not here, so handlers always pattern-match
  the *target* (field) and the *environment* (this struct) separately.

  Fields:

    * `:scope` — Ash actor scope the sheet is staged or corrected as.
    * `:tenant` — the tenant the bulk action acts in (or `nil`), which
      correcting a sheet need not be the one `:scope` acts in now.

  A field's companion file is not here: it is staged, not downloaded, when
  a sheet is mapped, and the resolver that reads it gets it from the worker.
  """

  defstruct [:scope, :tenant]

  @type t :: %__MODULE__{scope: term(), tenant: term() | nil}
end
