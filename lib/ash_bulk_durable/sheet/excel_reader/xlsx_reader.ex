defmodule AshBulkDurable.Sheet.ExcelReader.XlsxReader do
  @moduledoc """
  An `AshBulkDurable.Sheet.ExcelReader` in pure Elixir: reads an XLSX with
  [xlsx_reader](https://github.com/xavier/xlsx_reader), so no NIF is
  loaded. An app picks it with

      config :ash_bulk_durable, excel_reader: AshBulkDurable.Sheet.ExcelReader.XlsxReader

  It builds each row up to its last cell, so `:max_cells` counts the cells
  of every row read, blanks between included. It holds the whole sheet on
  the heap, 45 to 80 words a cell, so a sheet at the default 5,000,000
  cells takes a few gigabytes: a lower `:max_cells` suits it.

  It differs from the renderings `AshBulkDurable.Sheet.ExcelReader` lists
  for these cells:

    * a number in a cell with no style, as Excel writes a number in the
      General format, reads as the text the file stores, an exponent
      included (`1.2345678901234568E+16`, `1E-7`): xlsx_reader returns
      such a cell's text untyped, so it cannot be told from a text cell;
    * an elapsed time: xlsx_reader does not tell `[h]:mm` from a time of
      day. Under a custom format (`[h]:mm`) it reads as its stored number
      of days (`1.5` for 36 hours); under Excel's built-in `[h]:mm:ss` as a
      time of day below 24 hours (`09:00:00`) and a date-time from the
      workbook's base date beyond (`1899-12-31T12:00:00`);
    * text in a cell with no type (`t`) whose format is not a date or a
      time, such as the text format (`@`), reads as `#ERROR`; a valid file
      gives a text cell its type.

  Unlike `AshBulkDurable.Sheet.ExcelReader.Calamine`, it reads a date-time
  at midnight as a date-time (`2024-01-15T00:00:00`).
  """

  @behaviour AshBulkDurable.Sheet.ExcelReader

  @impl true
  def read(path, opts),
    do: read(path, Keyword.fetch!(opts, :sheet), Keyword.fetch!(opts, :max_cells))

  # xlsx_reader raises on some malformed files (a `FunctionClauseError` on
  # the error OTP 29's `:zip` gives for a file that is not a zip), so a
  # raise is an unreadable file too.
  defp read(path, sheet, max_cells) do
    with {:ok, package} <- open(path, sheet),
         {:ok, name} <- sheet_name(package, sheet),
         :ok <- within_columns(path, package, name, max_cells),
         {:ok, rows} <-
           XlsxReader.sheet(package, name,
             number_type: Float,
             empty_rows: false,
             skip_row?: skip_row(max_cells)
           ) do
      base_date = package.workbook.base_date
      {:ok, Enum.map(rows, fn row -> Enum.map(row, &cell(&1, base_date)) end)}
    else
      {:error, {tag, _value}} = error when tag in [:unknown_sheet, :too_many_cells] -> error
      {:error, reason} -> {:error, {:xlsx, reason}}
    end
  rescue
    error -> {:error, {:xlsx, error}}
  catch
    :throw, {__MODULE__, {:too_many_cells, _max_cells} = reason} -> {:error, reason}
  end

  # An index counts only the visible sheets, so the default is never a
  # hidden lookup sheet; a name finds a hidden sheet too.
  defp open(path, sheet) do
    with {:ok, package} <-
           XlsxReader.open(path,
             supported_custom_formats: custom_formats(),
             exclude_hidden_sheets?: is_integer(sheet)
           ) do
      {:ok, plain_numbers(package)}
    end
  end

  defp sheet_name(package, sheet) do
    names = XlsxReader.sheet_names(package)

    cond do
      is_integer(sheet) and sheet >= 0 and sheet < length(names) -> {:ok, Enum.at(names, sheet)}
      is_binary(sheet) and sheet in names -> {:ok, sheet}
      true -> {:error, {:unknown_sheet, sheet}}
    end
  end

  # xlsx_reader fills a row with blanks up to each cell's column before
  # `:max_cells` sees the row, so a far column (`ZZZZZZZ1` is column 8
  # billion) would build billions of cells from a file of a few bytes. A
  # cell whose column name is longer than the `max_cells`th column's is
  # refused first, being past `max_cells`; one no longer fills a row with at
  # most 26 × `max_cells` cells, and the count stops the read after it. The
  # sheet is scanned with Saxy, the parser xlsx_reader reads it with, after
  # the same conversion to UTF-8, so it sees each `r` as xlsx_reader will
  # (an entity in it decoded, a `>` in another attribute skipped).
  defp within_columns(path, package, name, max_cells) do
    %XlsxReader.Sheet{rid: rid} = Enum.find(package.workbook.sheets, &(&1.name == name))

    with {:ok, target} <- Map.fetch(package.workbook.rels.sheets, rid),
         {:ok, [{_file, xml}]} <-
           :zip.extract(String.to_charlist(path), [
             {:file_list, [String.to_charlist(xl_path(target))]},
             :memory
           ]),
         {:ok, xml} <- utf8(xml),
         {:ok, :far} <- Saxy.parse_string(xml, __MODULE__.FarColumn, letters(max_cells)) do
      {:error, {:too_many_cells, max_cells}}
    else
      # A missing sheet part or malformed XML, xlsx_reader reports itself.
      _near_or_unreadable -> :ok
    end
  end

  # As xlsx_reader converts a sheet part with a UTF-16 or UTF-32 byte-order
  # mark, and strips a UTF-8 one.
  defp utf8(xml) do
    {encoding, bom} = :unicode.bom_to_encoding(xml)
    xml = binary_part(xml, bom, byte_size(xml) - bom)

    case encoding do
      encoding when encoding in [:latin1, :utf8] ->
        {:ok, xml}

      encoding ->
        with utf8 when is_binary(utf8) <- :unicode.characters_to_binary(xml, encoding),
             do: {:ok, utf8}
    end
  end

  defmodule FarColumn do
    @moduledoc false
    # Stops at the first cell whose column name, the leading capitals of its
    # `r` (all xlsx_reader reads as a column), is longer than the state.
    # Saxy keeps a repeated attribute, and xlsx_reader takes the last `r`,
    # so every `r` is checked.
    @behaviour Saxy.Handler

    @impl true
    def handle_event(:start_element, {"c", attributes}, letters) do
      if Enum.any?(attributes, fn {name, value} ->
           name == "r" and capitals(value, 0) > letters
         end),
         do: {:stop, :far},
         else: {:ok, letters}
    end

    def handle_event(_event, _data, letters), do: {:ok, letters}

    defp capitals(<<c, rest::binary>>, count) when c in ?A..?Z, do: capitals(rest, count + 1)
    defp capitals(_rest, count), do: count
  end

  # The length of the `column`th column's name: 1 up to Z (26), 2 up to ZZ
  # (702), and so on.
  defp letters(column, length \\ 1, last \\ 26)
  defp letters(column, length, last) when column <= last, do: length
  defp letters(column, length, last), do: letters(column, length + 1, last * 26 + 26)

  # As xlsx_reader resolves a relationship target.
  defp xl_path("xl/" <> _ = target), do: target
  defp xl_path(target), do: Path.join("xl", target)

  # Called with each row once built, its blanks included: counts its cells
  # and stops the read past `max_cells`, and skips a blank row.
  defp skip_row(max_cells) do
    counter = :counters.new(1, [])

    fn row ->
      :counters.add(counter, 1, length(row))

      if :counters.get(counter, 1) > max_cells,
        do: throw({__MODULE__, {:too_many_cells, max_cells}})

      Enum.all?(row, &(&1 == "" or &1 == :expect_chars))
    end
  end

  # xlsx_reader knows the built-in date formats and a few custom ones; any
  # other custom format reads as a number. A format is a date if it has a d
  # or y outside quoted text, `[...]` sections, `\x` escapes and `_x`
  # padding, a time if it has an h or s there, a date-time if both. (An m is
  # a month or a minute, so it decides nothing.) An elapsed time (`[h]`,
  # `[m]`, `[s]`) is neither, and reads as a number of days.
  defp custom_formats do
    token = ~S{\[[^\]]*\]|"[^"]*"|\\.|_.|}
    without = &"(?:#{token}[^\"\[\\\\_#{&1}])*"

    [
      {~r/\[(?:h+|m+|s+)\]/i, :number},
      {Regex.compile!("\\A(?=#{without.("dDyY")}[dDyY])(?=#{without.("hHsS")}[hHsS])"),
       :date_time},
      {Regex.compile!("\\A#{without.("dDyYhHsS")}[dDyY]#{without.("hHsS")}\\z"), :date},
      {Regex.compile!("\\A#{without.("dDyY")}[hHsS]#{without.("dDyY")}\\z"), :time}
    ]
  end

  # xlsx_reader multiplies a percentage by 100, but only for a number cell
  # with no explicit `t="n"` (as Excel writes it, not openpyxl), and returns
  # such a cell's stored text when it does not know its format (a currency,
  # a fraction, a custom format the patterns above do not match). Reading
  # all of them as plain numbers gives the stored value, 0.15 for 15%,
  # whichever program wrote the file. This edits `style_types`, a typed
  # field of `XlsxReader.Workbook`, `nil` for a workbook with no styles.
  defp plain_numbers(%{workbook: %{style_types: nil}} = package), do: package

  defp plain_numbers(package) do
    update_in(package.workbook.style_types, fn types ->
      :array.map(
        fn
          _index, type when type in [:percentage, :unsupported, nil] -> :number
          _index, type -> type
        end,
        types
      )
    end)
  end

  # Numbers come as floats (`number_type: Float`), as calamine reads them;
  # `Decimal.from_float/1` takes their shortest round-tripping digits, and
  # normalising drops the `.0` of a whole number. A time of day is a
  # date-time on the workbook's base date.
  defp cell(value, _base_date) when is_binary(value), do: value
  defp cell(true, _base_date), do: "true"
  defp cell(false, _base_date), do: "false"

  defp cell(number, _base_date) when is_float(number),
    do: number |> Decimal.from_float() |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp cell(%Date{} = date, _base_date), do: Date.to_iso8601(date)

  defp cell(%NaiveDateTime{} = datetime, base_date) do
    if NaiveDateTime.to_date(datetime) == base_date,
      do: datetime |> NaiveDateTime.to_time() |> Time.to_iso8601(),
      else: NaiveDateTime.to_iso8601(datetime)
  end
end
