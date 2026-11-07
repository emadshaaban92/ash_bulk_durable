defmodule AshBulkDurable.Sheet.ReadTest do
  @moduledoc """
  `AshBulkDurable.Sheet.read/2` on an XLSX: every kind of cell reads as the
  string a CSV of the sheet would hold. The workbook is built here from its
  XML parts, so each cell's stored form is in plain sight.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Sheet

  # Cell styles, by index into `cellXfs`: 0 general, then the built-in
  # number formats for a date (14), a date-time (22), a time (21) and a
  # percentage (9), then custom formats for a date, a date-time, a time and
  # an elapsed time.
  @styles """
  <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <numFmts count="4">
      <numFmt numFmtId="164" formatCode="dd\-mmm\-yyyy"/>
      <numFmt numFmtId="165" formatCode="[$-409]d-mmm-yy h:mm AM/PM;@"/>
      <numFmt numFmtId="166" formatCode="h:mm AM/PM"/>
      <numFmt numFmtId="167" formatCode="[h]:mm:ss"/>
    </numFmts>
    <fonts count="1"><font/></fonts>
    <fills count="1"><fill/></fills>
    <borders count="1"><border/></borders>
    <cellStyleXfs count="1"><xf numFmtId="0"/></cellStyleXfs>
    <cellXfs count="9">
      <xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="22"/><xf numFmtId="21"/><xf numFmtId="9"/>
      <xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="166"/><xf numFmtId="167"/>
    </cellXfs>
  </styleSheet>
  """

  # A dropdown list sourced from another sheet, the x14 extension that made
  # csvkit print a warning into the CSV it returned.
  @dropdown """
  <extLst><ext uri="{CCE6A557-97BC-4b89-ADB6-D9C93CAAB3DF}"
    xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">
    <x14:dataValidations count="1" xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">
      <x14:dataValidation type="list"><x14:formula1><xm:f>Lists!$A$1:$A$2</xm:f></x14:formula1>
      <xm:sqref>N2:N10</xm:sqref></x14:dataValidation>
    </x14:dataValidations>
  </ext></extLst>
  """

  @data [
    ~w(name qty big price share share_n when midnight day clock flag zip total pick cday cwhen cclock span oops),
    [
      "Ann",
      {:n, "3"},
      {:n, "1.2345678901234568E+16"},
      {:n, "19.99"},
      {:n, "0.15", 4},
      {:tn, "0.15", 4},
      {:n, "45306.5", 2},
      {:n, "45306", 2},
      {:n, "45352", 1},
      {:n, "0.375", 3},
      {:b, "1"},
      "01234",
      {:f, "B2*2", "6"},
      "red",
      {:n, "45352", 5},
      {:n, "45306.5", 6},
      {:n, "0.375", 7},
      {:n, "1.5", 8},
      {:e, "#DIV/0!"}
    ],
    [],
    ["Bob", {:n, "-0.5"}, {:n, "1E-7"}, nil, nil, nil, nil, nil, nil, nil, {:b, "0"}, " 99 "]
  ]

  @lists [["red"], ["blue"]]

  setup do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-cells.xlsx")
    File.write!(path, workbook([{"Data", @data, @dropdown}, {"Lists", @lists, ""}]))
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "reads every kind of cell as a CSV would hold it", %{path: path} do
    assert {:ok, %Sheet{headers: headers, rows: [ann, bob]}} = Sheet.read(path)

    assert headers ==
             ~w(name qty big price share share_n when midnight day clock flag zip total pick cday cwhen cclock span oops)

    assert ann == %{
             "name" => "Ann",
             "qty" => "3",
             "big" => "12345678901234568",
             "price" => "19.99",
             # 15%, read as its stored value whether or not the cell says t="n"
             "share" => "0.15",
             "share_n" => "0.15",
             "when" => "2024-01-15T12:00:00",
             # The file does not say whether a midnight is a date or a
             # date-time, so it reads as a date.
             "midnight" => "2024-01-15",
             "day" => "2024-03-01",
             "clock" => "09:00:00",
             "flag" => "true",
             "zip" => "01234",
             "total" => "6",
             "pick" => "red",
             "cday" => "2024-03-01",
             "cwhen" => "2024-01-15T12:00:00",
             "cclock" => "09:00:00",
             "span" => "PT36H",
             "oops" => "#DIV/0!"
           }

    # A row shorter than the header reads blank for the rest; cells are
    # trimmed; the blank row between is dropped.
    assert bob == %{
             "name" => "Bob",
             "qty" => "-0.5",
             "big" => "0.0000001",
             "price" => "",
             "share" => "",
             "share_n" => "",
             "when" => "",
             "midnight" => "",
             "day" => "",
             "clock" => "",
             "flag" => "false",
             "zip" => "99",
             "total" => "",
             "pick" => "",
             "cday" => "",
             "cwhen" => "",
             "cclock" => "",
             "span" => "",
             "oops" => ""
           }
  end

  test ":sheet picks a sheet by name or index", %{path: path} do
    assert {:ok, %Sheet{headers: ["red"], rows: [%{"red" => "blue"}]}} =
             Sheet.read(path, sheet: "Lists")

    assert {:ok, %Sheet{headers: ["red"]}} = Sheet.read(path, sheet: 1)
    assert {:error, {:unknown_sheet, "Nope"}} = Sheet.read(path, sheet: "Nope")
    assert {:error, {:unknown_sheet, 2}} = Sheet.read(path, sheet: 2)
  end

  test "the default sheet and an index skip hidden sheets; a name finds one" do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-hidden.xlsx")
    File.write!(path, workbook([{"HiddenLookup", [["x"]], ""}, {"Data", [["a"], ["1"]], ""}]))
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %Sheet{headers: ["a"], rows: [%{"a" => "1"}]}} = Sheet.read(path)
    assert {:ok, %Sheet{headers: ["a"]}} = Sheet.read(path, sheet: 0)
    assert {:error, {:unknown_sheet, 1}} = Sheet.read(path, sheet: 1)
    assert {:ok, %Sheet{headers: ["x"], rows: []}} = Sheet.read(path, sheet: "HiddenLookup")
  end

  # calamine builds the whole rectangle from A1, so one far cell costs its
  # row × column count, whatever the file's size.
  test ":max_cells caps the rows × columns read", %{path: path} do
    assert {:error, {:xlsx, reason}} = Sheet.read(path, max_cells: 50)
    assert reason =~ "max_cells"
    assert {:ok, %Sheet{}} = Sheet.read(path, max_cells: 100)
  end

  test "a file that is not a workbook is an error, not a raise" do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-broken.xlsx")
    File.write!(path, "not a workbook")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:xlsx, _reason}} = Sheet.read(path)
    assert {:error, %File.Error{}} = Sheet.read("/nonexistent/sheet.xlsx")
  end

  # ---- Building the workbook ------------------------------------------------

  defp workbook(sheets) do
    indexed = Enum.with_index(sheets, 1)

    parts =
      [
        {"[Content_Types].xml", content_types(indexed)},
        {"_rels/.rels", root_rels()},
        {"xl/workbook.xml", workbook_xml(indexed)},
        {"xl/_rels/workbook.xml.rels", workbook_rels(indexed)},
        {"xl/styles.xml", @styles}
      ] ++
        for {{_name, rows, ext}, i} <- indexed,
            do: {"xl/worksheets/sheet#{i}.xml", sheet_xml(rows, ext)}

    {:ok, {_name, zip}} =
      :zip.create(~c"cells.xlsx", Enum.map(parts, fn {n, x} -> {String.to_charlist(n), x} end), [
        :memory
      ])

    zip
  end

  defp content_types(indexed) do
    sheets =
      for {_, i} <- indexed,
          do:
            ~s(<Override PartName="/xl/worksheets/sheet#{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)

    """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
      #{sheets}
    </Types>
    """
  end

  defp root_rels do
    """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """
  end

  defp workbook_xml(indexed) do
    sheets =
      for {{name, _, _}, i} <- indexed do
        state = if String.starts_with?(name, "Hidden"), do: ~s( state="hidden"), else: ""
        ~s(<sheet name="#{name}" sheetId="#{i}" r:id="rId#{i}"#{state}/>)
      end

    """
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>#{sheets}</sheets>
    </workbook>
    """
  end

  defp workbook_rels(indexed) do
    sheets =
      for {_, i} <- indexed,
          do:
            ~s(<Relationship Id="rId#{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{i}.xml"/>)

    styles =
      ~s(<Relationship Id="rId#{length(indexed) + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>)

    """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      #{sheets}#{styles}
    </Relationships>
    """
  end

  defp sheet_xml(rows, ext) do
    rows =
      for {cells, r} <- Enum.with_index(rows, 1) do
        cells =
          for {cell, c} <- Enum.with_index(cells),
              cell != nil,
              do: cell_xml(cell, "#{<<?A + c>>}#{r}")

        ~s(<row r="#{r}">#{cells}</row>)
      end

    """
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>#{rows}</sheetData>#{ext}
    </worksheet>
    """
  end

  defp cell_xml(text, ref) when is_binary(text),
    do: ~s(<c r="#{ref}" t="inlineStr"><is><t xml:space="preserve">#{text}</t></is></c>)

  defp cell_xml({:n, value}, ref), do: cell_xml({:n, value, 0}, ref)
  defp cell_xml({:n, value, style}, ref), do: ~s(<c r="#{ref}" s="#{style}"><v>#{value}</v></c>)

  defp cell_xml({:tn, value, style}, ref),
    do: ~s(<c r="#{ref}" s="#{style}" t="n"><v>#{value}</v></c>)

  defp cell_xml({:b, value}, ref), do: ~s(<c r="#{ref}" t="b"><v>#{value}</v></c>)
  defp cell_xml({:e, code}, ref), do: ~s(<c r="#{ref}" t="e"><v>#{code}</v></c>)

  defp cell_xml({:f, formula, cached}, ref),
    do: ~s(<c r="#{ref}"><f>#{formula}</f><v>#{cached}</v></c>)
end
