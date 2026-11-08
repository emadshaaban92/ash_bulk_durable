defmodule AshBulkDurable.Sheet.ExcelReader.Calamine do
  @moduledoc """
  The default `AshBulkDurable.Sheet.ExcelReader`: reads an XLSX with
  [calamine](https://github.com/tafia/calamine), a Rust library, through
  the `spreadsheet` package's precompiled NIF.

  calamine builds the sheet's whole rectangle from A1, so `:max_cells`
  counts rows × columns from A1: a small file with one cell far from A1
  would otherwise take gigabytes. It also reports a date and a date-time
  the same way, so a date-time at exactly midnight reads as a date
  (`2024-01-15`).
  """

  @behaviour AshBulkDurable.Sheet.ExcelReader

  @impl true
  def read(path, opts) do
    sheet = Keyword.fetch!(opts, :sheet)
    max_cells = Keyword.fetch!(opts, :max_cells)

    with {:ok, name} <- sheet_name(path, sheet, max_cells),
         {:ok, rows} <-
           xlsx(Spreadsheet.parse(path, sheet: name, max_cells: max_cells), max_cells) do
      {:ok, Enum.map(rows, fn row -> Enum.map(row, &cell/1) end)}
    end
  end

  # `spreadsheet` reports going over `:max_cells` only in its message, each
  # kind ending "above the :max_cells limit of N" or "... cells left of the
  # :max_cells limit of N ...".
  defp xlsx(result, max_cells) do
    case result do
      {:ok, _value} = ok ->
        ok

      {:error, reason} ->
        if reason =~ ":max_cells limit of",
          do: {:error, {:too_many_cells, max_cells}},
          else: {:error, {:xlsx, reason}}
    end
  end

  # An index counts only the visible sheets, so the default is never a
  # hidden lookup sheet; a name finds a hidden sheet too.
  defp sheet_name(path, sheet, max_cells) do
    with {:ok, names} <-
           xlsx(
             Spreadsheet.sheet_names(path, hidden: is_binary(sheet), max_cells: max_cells),
             max_cells
           ) do
      cond do
        is_integer(sheet) and sheet >= 0 and sheet < length(names) ->
          {:ok, Enum.at(names, sheet)}

        is_binary(sheet) and sheet in names ->
          {:ok, sheet}

        true ->
          {:error, {:unknown_sheet, sheet}}
      end
    end
  end

  # calamine reads every number as a float; `Decimal.from_float/1` takes its
  # shortest round-tripping digits, and normalising drops the `.0` of a
  # whole number.
  defp cell(value) when is_binary(value), do: value
  defp cell(nil), do: ""
  defp cell(true), do: "true"
  defp cell(false), do: "false"
  defp cell({:error, code}), do: code

  defp cell(number) when is_float(number),
    do: number |> Decimal.from_float() |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp cell(%NaiveDateTime{} = datetime) do
    if NaiveDateTime.to_time(datetime) == ~T[00:00:00],
      do: datetime |> NaiveDateTime.to_date() |> Date.to_iso8601(),
      else: NaiveDateTime.to_iso8601(datetime)
  end

  defp cell(%Time{} = time), do: Time.to_iso8601(time)
  defp cell(%Duration{} = duration), do: Duration.to_iso8601(duration)
end
