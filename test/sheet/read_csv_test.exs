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

  defp read(csv, %{tmp_dir: dir}) do
    path = Path.join(dir, "sheet.csv")
    File.write!(path, csv)
    Sheet.read(path)
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
end
