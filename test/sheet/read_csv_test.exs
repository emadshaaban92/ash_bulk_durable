defmodule AshBulkDurable.Sheet.ReadCsvTest do
  @moduledoc """
  `AshBulkDurable.Sheet.read/2` on a CSV whose shape does not match its
  header: a short row reads its missing cells as blank, a long one is
  refused unless the cells past the header are blank, and two columns under
  one header are refused rather than collapsed.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Sheet

  @moduletag :tmp_dir

  defp read(csv, %{tmp_dir: dir}, opts \\ []) do
    path = Path.join(dir, "sheet.csv")
    File.write!(path, csv)
    Sheet.read(path, opts)
  end

  test "a short row reads its missing cells as blank", context do
    assert {:ok, %Sheet{headers: ["name", "qty", "note"], rows: rows}} =
             read("name,qty,note\nAnn,3\nBob\n", context)

    assert rows == [
             %{"name" => "Ann", "qty" => "3", "note" => ""},
             %{"name" => "Bob", "qty" => "", "note" => ""}
           ]
  end

  test "blank cells past the last header, a trailing comma's, are dropped", context do
    assert {:ok, %Sheet{rows: [%{"name" => "Ann", "qty" => "3"}]}} =
             read("name,qty\nAnn,3,, \n", context)
  end

  test "a filled cell past the last header is refused, naming its row", context do
    assert {:error, {:extra_cells, 3}} =
             read("name,price\nAnn,3\nBob,1,000\nCy,2\n", context)
  end

  test "a long row is named by its row even after a blank row", context do
    assert {:error, {:extra_cells, 4}} = read("name\nAnn\n\nBob,x\n", context)
  end

  test "blank lines above the header are skipped, and counted", context do
    assert {:ok, %Sheet{headers: ["name"], rows: [%{"name" => "Ann"}]}} =
             read("\n,\nname\nAnn\n", context)

    assert {:error, {:extra_cells, 4}} = read("\nname\nAnn\nBob,x\n", context)
  end

  test "two columns under one header are refused, not collapsed", context do
    assert {:error, {:duplicate_headers, ["name", "qty"]}} =
             read("name,qty,name,qty,note\nAnn,3,Bob,4,x\n", context)
  end

  test "blank headers may repeat; those after the last named one are dropped", context do
    assert {:ok,
            %Sheet{headers: ["name", "", " ", "qty"], rows: [%{"name" => "Ann", "qty" => "3"}]}} =
             read("name,, ,qty,,\nAnn,,,3,,\n", context)
  end

  test "a filled cell under a blank header past the last named one is refused", context do
    assert {:error, {:extra_cells, 2}} = read("name,qty,\nAnn,3,x\n", context)
  end

  describe ":max_cells" do
    test "counts the cells on every line, a blank line being one", context do
      csv = "name,qty\nAnn,3\n\n"

      assert {:ok, %Sheet{rows: [%{"name" => "Ann"}]}} = read(csv, context, max_cells: 5)
      assert {:error, {:too_many_cells, 4}} = read(csv, context, max_cells: 4)
    end

    test "a comma or line break in quotes opens no cell, nor does a doubled quote", context do
      csv = ~s("a,b",c\n"x\n""y"",z",w\n)

      assert {:ok, %Sheet{headers: ["a,b", "c"], rows: [row]}} = read(csv, context, max_cells: 4)
      assert row == %{"a,b" => ~s(x\n"y",z), "c" => "w"}
      assert {:error, {:too_many_cells, 3}} = read(csv, context, max_cells: 3)
    end

    test "one line of more cells than the cap is refused", context do
      csv = "name" <> String.duplicate(",", 1_000_000) <> "\n"

      assert {:error, {:too_many_cells, 10}} = read(csv, context, max_cells: 10)
    end

    test "a quote inside a cell, as an inch mark, refuses only its own row", context do
      assert {:error, %NimbleCSV.ParseError{message: message}} =
               read("a,b\nx\"y,z\n1,2\n", context, max_cells: 4)

      assert message =~ ~s(x\\"y,z)
      refute message =~ "1,2"
    end
  end

  test "a refused row is quoted in the error only so far", context do
    assert {:error, %NimbleCSV.ParseError{message: message}} =
             read("a\nx\"" <> String.duplicate("y", 10_000) <> "\n", context)

    assert String.length(message) == 201
    assert String.ends_with?(message, "…")
  end

  test "a CSV of many chunks reads whole, a quoted cell across a chunk's end included",
       context do
    rows = Enum.map(1..8_000, &["n#{&1}", ~s(line one,\nline "#{&1}")])
    csv = NimbleCSV.RFC4180.dump_to_iodata([["name", "note"] | rows])

    assert {:ok, %Sheet{headers: ["name", "note"], rows: read_rows}} =
             read(["\uFEFF" | csv], context)

    assert IO.iodata_length(csv) > 3 * 65_536
    assert read_rows == Enum.map(rows, fn [name, note] -> %{"name" => name, "note" => note} end)
  end
end
