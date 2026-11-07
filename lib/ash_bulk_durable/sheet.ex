defmodule AshBulkDurable.Sheet do
  @moduledoc """
  The sheet layer: reads a CSV or XLSX into a `%AshBulkDurable.Sheet{}` of
  headers and rows (`read/2`), turns its rows into the target + input rows
  the core runs (`AshBulkDurable.Sheet.Mapping`), stages them as a bulk
  action (`stage/3`), and turns the rows that have not succeeded into a
  sheet to correct and back (`AshBulkDurable.Sheet.ErrorsSheet`). It calls
  the core; the core never calls it.

  Owns the **handler resolver**: every mapped field goes through the first
  handler whose `handles?/1` returns true. Apps register their own handlers
  via config; the defaults cover the common scalar / `belongs_to` cases.

      config :ash_bulk_durable,
        field_handlers: [MyApp.CustomImageHandler],
        disable_defaults: []

  `:field_handlers` is **prepended** to the defaults, so a custom handler
  beats the built-in one for any field both claim. `:disable_defaults` is
  the escape hatch — list the default modules you want stripped from the
  resolution list entirely. Use `default_handlers/0` to position a handler
  *after* the defaults: build the whole ordered list as `:field_handlers`
  and disable the originals.

  ## Override granularity

  Because each callback receives an `AshBulkDurable.Sheet.Field` struct
  (Ash field + resource + action), apps can override on any axis — by type,
  by resource, by action, or by exact tuple — through pattern matching in
  `handles?/1`:

      def handles?(%AshBulkDurable.Sheet.Field{
        resource: MyApp.Posts.Post,
        action: %{name: :create_with_validation},
        field: %{name: :attachments}
      }), do: true

      def handles?(_), do: false

  ## BelongsTo identity carveout

  `AshBulkDurable.Sheet.FieldHandlers.BelongsTo` takes the identity it
  looks a cell up by from the mapping's `rel_identities` (the screens'
  "Lookup by" dropdown) as its state, instead of from `prepare/2`. Apps
  that replace it with a custom handler module inherit none of this: their
  `prepare/2` is called normally and must source the identity elsewhere.
  """

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.{Owner, Runner}
  alias AshBulkDurable.Sheet.{Companions, Field, Mapping, PrepareContext}
  alias NimbleCSV.RFC4180, as: CSV

  @doc """
  A sheet read by `read/2`: its `headers` in the file's order, and its
  `rows`, each `%{header => cell}` with the cell trimmed. A row of blank
  cells is dropped.
  """
  defstruct headers: [], rows: []

  @doc """
  Reads the CSV or XLSX at `path`. The type is `path`'s extension unless
  `:type` (`:csv` or `:xlsx`) names it, as an upload's temporary path has
  none. A UTF-8 byte-order mark is stripped, so a file Excel saved reads
  cleanly. Returns `{:ok, %AshBulkDurable.Sheet{}}`, or `{:error, reason}`.

  An XLSX's cells are read as the strings a CSV of the same sheet would
  hold: a number as the digits the file stores (no float rounding or
  exponent), a percentage as its stored value (`0.15` for 15%), a boolean as
  `true`/`false`, a date, date-time or time as ISO 8601, a formula as its
  cached value. A cell xlsx_reader cannot convert (a date-time that rounds
  to 24:00:00, an elapsed time over 24 hours) reads as `#ERROR`. `:sheet`
  names the sheet to read, by name or 0-based index; the first sheet by
  default.
  """
  def read(path, opts \\ []) do
    case Keyword.get_lazy(opts, :type, fn -> type(path) end) do
      :csv ->
        {:ok,
         path |> File.read!() |> strip_bom() |> CSV.parse_string(skip_headers: false) |> build()}

      :xlsx ->
        read_xlsx(path, Keyword.get(opts, :sheet, 0))

      other ->
        {:error, {:unknown_type, other}}
    end
  rescue
    error in [File.Error, NimbleCSV.ParseError] -> {:error, error}
  end

  defp type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".xlsx" -> :xlsx
      ".csv" -> :csv
      other -> other
    end
  end

  defp read_xlsx(path, sheet) do
    with {:ok, package} <- open_xlsx(path),
         package = percentages_as_numbers(package),
         {:ok, name} <- sheet_name(package, sheet),
         {:ok, rows} <- XlsxReader.sheet(package, name, number_type: Decimal) do
      base_date = package.workbook.base_date
      {:ok, rows |> Enum.map(fn row -> Enum.map(row, &cell(&1, base_date)) end) |> build()}
    else
      {:error, {:unknown_sheet, _sheet}} = error -> error
      {:error, reason} -> {:error, {:xlsx, reason}}
    end
  end

  # xlsx_reader raises on some malformed archives instead of returning an
  # error (a `FunctionClauseError` on the error shape OTP 29's `:zip` gives
  # for a file that is not a zip), so a raise here is an unreadable file too.
  defp open_xlsx(path) do
    if File.regular?(path),
      do: XlsxReader.open(path, supported_custom_formats: custom_formats()),
      else: raise(File.Error, reason: :enoent, action: "read file", path: path)
  rescue
    error in [File.Error] -> reraise error, __STACKTRACE__
    error -> {:error, error}
  end

  # xlsx_reader knows the built-in date formats and a few custom ones; any
  # other custom format reads as a serial number. A format is a date if it
  # has a d or y outside quoted text, `[...]` sections, `\x` escapes and `_x`
  # padding, a time if it has an h or s there, a date-time if both. (An m is
  # a month or a minute, so it decides nothing.)
  defp custom_formats do
    token = ~S{\[[^\]]*\]|"[^"]*"|\\.|_.|}
    without = &"(?:#{token}[^\"\[\\\\_#{&1}])*"

    [
      {Regex.compile!("\\A(?=#{without.("dDyY")}[dDyY])(?=#{without.("hHsS")}[hHsS])"),
       :date_time},
      {Regex.compile!("\\A#{without.("dDyYhHsS")}[dDyY]#{without.("hHsS")}\\z"), :date},
      {Regex.compile!("\\A#{without.("dDyY")}[hHsS]#{without.("dDyY")}\\z"), :time}
    ]
  end

  # xlsx_reader multiplies a percentage by 100, but only for a number cell
  # with no explicit `t="n"` (as Excel writes it, not openpyxl or a custom
  # `0.000%`). Reading every percentage as a plain number gives the stored
  # value, 0.15 for 15%, whichever program wrote the file. This edits
  # `style_types`, a typed field of `XlsxReader.Workbook`.
  defp percentages_as_numbers(package) do
    update_in(package.workbook.style_types, fn types ->
      :array.map(
        fn
          _index, :percentage -> :number
          _index, type -> type
        end,
        types
      )
    end)
  end

  defp sheet_name(package, sheet) do
    names = XlsxReader.sheet_names(package)

    cond do
      is_integer(sheet) and sheet >= 0 and sheet < length(names) -> {:ok, Enum.at(names, sheet)}
      is_binary(sheet) and sheet in names -> {:ok, sheet}
      true -> {:error, {:unknown_sheet, sheet}}
    end
  end

  # A cell as a CSV of the sheet would hold it. Numbers come as `Decimal`
  # (`number_type: Decimal`), parsed from the text the file stores, so they
  # print without float rounding or an exponent; normalising drops trailing
  # zeros.
  # A time is a date-time on the workbook's base date.
  defp cell(value, _base_date) when is_binary(value), do: value
  defp cell(true, _base_date), do: "true"
  defp cell(false, _base_date), do: "false"
  defp cell(nil, _base_date), do: ""

  defp cell(%Decimal{} = number, _base_date),
    do: number |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp cell(%Date{} = date, _base_date), do: Date.to_iso8601(date)

  defp cell(%NaiveDateTime{} = datetime, base_date) do
    if NaiveDateTime.to_date(datetime) == base_date,
      do: datetime |> NaiveDateTime.to_time() |> Time.to_iso8601(),
      else: NaiveDateTime.to_iso8601(datetime)
  end

  defp build([]), do: %__MODULE__{}

  defp build([headers | rows]) do
    %__MODULE__{
      headers: headers,
      rows:
        rows
        |> Enum.map(fn row ->
          headers
          |> Enum.zip(Stream.concat(row, Stream.repeatedly(fn -> "" end)))
          |> Map.new(fn {k, v} -> {k, String.trim(v)} end)
        end)
        |> Enum.reject(fn row -> Enum.all?(row, fn {_header, cell} -> cell == "" end) end)
    }
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  @doc "`sheet` as a stream of CSV iodata, its headers first."
  def to_csv(%__MODULE__{headers: headers, rows: rows}) do
    [headers]
    |> Stream.concat(Stream.map(rows, fn row -> Enum.map(headers, &Map.get(row, &1, "")) end))
    |> CSV.dump_to_stream()
  end

  @default_handlers [
    AshBulkDurable.Sheet.FieldHandlers.Scalar,
    AshBulkDurable.Sheet.FieldHandlers.BelongsTo
  ]

  @doc """
  The built-in handlers, in the order they're consulted. Returned as a list
  so apps can compose against it explicitly.
  """
  def default_handlers, do: @default_handlers

  @doc """
  The active handler list from config: `app_handlers ++ default_handlers --
  disable_defaults`. First `handles?/1` to return `true` wins.
  """
  def handlers do
    app_handlers = AshBulkDurable.Core.config(:field_handlers, [])
    disable_defaults = AshBulkDurable.Core.config(:disable_defaults, [])

    (app_handlers ++ @default_handlers) -- disable_defaults
  end

  @doc """
  The first handler that claims `field`, or `nil` if none does (the field
  can't be mapped).
  """
  def handler_for(%Field{} = field), do: Enum.find(handlers(), & &1.handles?(field))

  @doc """
  Stages `rows` (a sheet's rows, `%{header => cell}` each) as a bulk action
  running `mapping`'s action, queued for the worker. Returns `{:ok,
  bulk_action}`, or `{:error, error}` without storing anything. Raises
  `ArgumentError` for an update or destroy with no identity in `mapping`.

  Options:

    * `:scope` (required), `:tenant`, `:mode`, `:chunk_size` — as
      `AshBulkDurable.Core.create/4` takes them.
    * `:companions` — `%{field_name => staging_key}`: the files staged for
      fields with a companion requirement, under the owner's staging
      prefix.
  """
  def stage(rows, %Mapping{} = mapping, opts) do
    scope = Keyword.fetch!(opts, :scope)
    companions = Keyword.get(opts, :companions, %{})
    tenant = Keyword.get_lazy(opts, :tenant, fn -> Runner.scope_tenant(scope) end)
    Mapping.identified!(mapping)

    with :ok <- Companions.check(mapping, companions, Owner.worker_key(scope)),
         {:ok, rows} <- Mapping.rows(mapping, rows, %PrepareContext{scope: scope, tenant: tenant}) do
      Core.create(
        mapping.resource,
        mapping.action.name,
        rows,
        opts
        |> Keyword.take([:scope, :tenant, :mode, :chunk_size])
        |> Keyword.merge(
          staged_files: Map.new(companions, fn {name, key} -> {to_string(name), key} end),
          metadata: Mapping.to_metadata(mapping)
        )
      )
    end
  end
end
