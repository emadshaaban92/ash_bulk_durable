defmodule AshBulkDurable.Sheet.ExcelReader do
  @moduledoc """
  Behaviour for reading an XLSX into rows of cells, for
  `AshBulkDurable.Sheet.read/2`. The default is
  `AshBulkDurable.Sheet.ExcelReader.Calamine`; an app picks another with

      config :ash_bulk_durable, excel_reader: MyApp.ExcelReader

  A reader returns every cell as the string a CSV of the same sheet would
  hold. Every reader aims for the renderings below; a reader's moduledoc
  names the cells where it differs (for `ExcelReader.Calamine`, a date-time
  at exactly midnight):

    * a number as its shortest decimal form, without an exponent or a
      trailing `.0` (`3`, `19.99`, `12345678901234568`, `0.0000001`);
    * a percentage as its stored value (`0.15` for 15%);
    * a boolean as `true` or `false`;
    * a date as `2024-03-01`, a date-time as `2024-01-15T12:00:00`, a time
      of day as `09:00:00`, an elapsed time (`[h]:mm`) as an ISO 8601
      duration (`PT36H`);
    * a formula as its cached value, a formula error as its code
      (`#DIV/0!`);
    * an empty cell as `""`.

  `Sheet` trims each cell, pads a short row with `""` and drops blank rows,
  so a reader need not. A reader should keep blank rows, those above the
  header included, as rows of `""`: `Sheet` names a row by its place in
  the list, which is then its row number in the sheet.
  """

  @typedoc """
  Options `Sheet` always passes:

    * `:sheet` — the sheet to read: a name (a hidden sheet included), or a
      0-based index among the visible sheets.
    * `:max_cells` — the most cells the reader may build for the sheet.
  """
  @type opts :: [sheet: String.t() | non_neg_integer(), max_cells: pos_integer()]

  @doc """
  Reads the sheet `opts` names from the XLSX at `path`, an existing file.
  Returns its rows from the sheet's first, the header row first after any
  blank ones, each a list of cells as above.
  Returns `{:error, {:too_many_cells, max_cells}}` for a sheet over
  `:max_cells`, `{:error, {:unknown_sheet, sheet}}` for a sheet the file
  does not have, and `{:error, {:xlsx, reason}}` for a file it cannot read.
  It must not raise on a malformed file.
  """
  @callback read(path :: Path.t(), opts()) ::
              {:ok, [[String.t()]]}
              | {:error,
                 {:too_many_cells, pos_integer()}
                 | {:unknown_sheet, String.t() | non_neg_integer()}
                 | {:xlsx, term()}}
end
