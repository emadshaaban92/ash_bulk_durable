defmodule AshBulkDurable.Sheet.ExcelReaderTest do
  @moduledoc """
  `AshBulkDurable.Sheet.read/2` reads an XLSX through the configured
  `AshBulkDurable.Sheet.ExcelReader`. Not async: it sets app config.
  """
  use ExUnit.Case, async: false

  alias AshBulkDurable.Sheet

  defmodule EchoReader do
    @moduledoc false
    @behaviour AshBulkDurable.Sheet.ExcelReader

    @impl true
    def read(_path, sheet: "Nope", max_cells: _max_cells), do: {:error, {:unknown_sheet, "Nope"}}

    def read(_path, opts) do
      {:ok, [["sheet", "max_cells"], [inspect(opts[:sheet]), " #{opts[:max_cells]} "], ["", ""]]}
    end
  end

  setup do
    previous = Application.fetch_env(:ash_bulk_durable, :excel_reader)
    Application.put_env(:ash_bulk_durable, :excel_reader, EchoReader)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_bulk_durable, :excel_reader, value)
        :error -> Application.delete_env(:ash_bulk_durable, :excel_reader)
      end
    end)

    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-any.xlsx")
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "the configured reader reads the sheet, with the defaults filled in", %{path: path} do
    # Its cells are trimmed and its blank rows dropped, as a CSV's are.
    assert {:ok, %Sheet{headers: ["sheet", "max_cells"], rows: [row]}} = Sheet.read(path)
    assert row == %{"sheet" => "0", "max_cells" => "5000000"}

    assert {:ok, %Sheet{rows: [%{"sheet" => ~s("Data"), "max_cells" => "10"}]}} =
             Sheet.read(path, sheet: "Data", max_cells: 10)

    assert {:error, {:unknown_sheet, "Nope"}} = Sheet.read(path, sheet: "Nope")
  end

  test "a missing file is an error before the reader runs" do
    assert {:error, %File.Error{}} = Sheet.read("/nonexistent/sheet.xlsx")
  end
end
