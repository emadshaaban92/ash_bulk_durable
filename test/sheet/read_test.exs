defmodule AshBulkDurable.Sheet.ReadTest do
  @moduledoc """
  `AshBulkDurable.Sheet.read/2` on a real workbook, through `in2csv`.
  `test/fixtures/make_workbooks.py` writes it.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Sheet
  alias AshBulkDurable.Sheet.{Mapping, PrepareContext}
  alias AshBulkDurable.Test.Shelf

  @workbook Path.expand("../fixtures/workbook.xlsx", __DIR__)

  test "reads the first sheet's cells, though openpyxl warns about its dropdown" do
    assert {:ok, %Sheet{headers: headers, rows: rows}} = Sheet.read(@workbook)

    assert headers == ["code", "open", "note", "since", "rate", "checked"]

    # Dates in custom formats read as dates, a percentage as its value.
    assert rows == [
             %{
               "code" => "S1",
               "open" => "True",
               "note" => "True",
               "since" => "2024-03-01",
               "rate" => "0.15",
               "checked" => "2024-03-01 09:30:00"
             },
             %{
               "code" => "S2",
               "open" => "False",
               "note" => "no",
               "since" => "2024-12-31",
               "rate" => "1",
               "checked" => "2024-12-31 23:59:05"
             }
           ]
  end

  test "a workbook's TRUE and FALSE cells create records" do
    {:ok, sheet} = Sheet.read(@workbook)

    mapping = %Mapping{
      resource: Shelf,
      action: Ash.Resource.Info.action(Shelf, :create),
      columns: %{code: "code", open: "open", serial: "note"}
    }

    {:ok, rows} = Mapping.rows(mapping, sheet.rows, %PrepareContext{})

    created =
      Enum.map(rows, fn %{input: input} ->
        Shelf |> Ash.Changeset.for_create(:create, input) |> Ash.create!(authorize?: false)
      end)

    # A text cell keeps its case; only a boolean field's is lowered.
    assert Enum.map(created, &{&1.code, &1.open, &1.serial}) ==
             [{"S1", true, "True"}, {"S2", false, "no"}]
  end

  test "a file that is no workbook is in2csv's error, not its CSV" do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-broken.xlsx")
    File.write!(path, "not a workbook")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:in2csv, status, message}} = Sheet.read(path)
    assert status != 0
    assert message =~ "BadZipFile"
  end
end
