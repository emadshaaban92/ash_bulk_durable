defmodule ExampleWeb.Bulk.RefusedSheetTest do
  @moduledoc """
  A sheet `AshBulkDurable.read_sheet/2` refuses, uploaded on `/bulk`: the
  page says why and stays up, in the submit form and in the retry zone.
  """
  use ExampleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshBulkDurable.Core.Worker
  alias Example.BulkActions.{BulkAction, Row}

  require Ash.Query

  @refusals [
    duplicate_headers:
      {"code,name,code\nA,Region A,B\n",
       "the header code is on more than one column. Give each column its own header."},
    duplicate_headers_twice:
      {"code,name,code,name\nA,Region A,B,Region B\n",
       "the headers code, name are each on more than one column."},
    extra_cells:
      {"code,name\nA,Region A\nB,Region, B\n",
       "row 3 has a cell past the last header, often a comma that should be quoted."},
    malformed_quote: {"code,name\nA,\"Region A\n", "it isn't a readable spreadsheet or CSV."}
  ]

  defp region_rows do
    tag = "RS#{System.unique_integer([:positive])}"

    Enum.map(1..2, fn n ->
      %{code: "#{tag}#{n}", name: "Region #{tag}#{n}", native_name: "منطقة #{tag}#{n}"}
    end)
  end

  defp to_csv(rows) do
    ["code,name,native_name" | Enum.map(rows, &"#{&1.code},#{&1.name},#{&1.native_name}")]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp choose_region_create(view) do
    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => "region"})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => "create"})

    view
  end

  defp upload_sheet(view, content) do
    view
    |> file_input("#main_form", :sheet, [
      %{name: "regions.csv", content: content, type: "text/csv"}
    ])
    |> render_upload("regions.csv")
  end

  defp upload_retry(view, content) do
    view
    |> file_input("#retry-upload-form", :retry_csv, [
      %{name: "corrections.csv", content: content, type: "text/csv"}
    ])
    |> render_upload("corrections.csv")
  end

  # A bulk action parked in `:completed_with_errors`: its second row repeats
  # the first's unique code.
  defp parked_bulk_action(conn, user) do
    [first, second] = region_rows()
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    upload_sheet(choose_region_create(view), to_csv([first, %{second | code: first.code}]))
    view |> form("#main_form") |> render_submit()
    render_async(view, 2000)
    assert 1 = Worker.drain()

    bulk_action =
      BulkAction
      |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user.id})
      |> Ash.read_one!(authorize?: false)

    assert bulk_action.status == :completed_with_errors
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    {view, bulk_action, second}
  end

  defp staged?(view), do: has_element?(view, "#retry-upload-form span", "corrections.csv")

  defp flash?(view, text), do: has_element?(view, "#flash-error", text)

  defp retry_disabled?(view),
    do: has_element?(view, "#bulk-action-panel button[disabled]", "Retry failed rows")

  defp retry_button(view), do: element(view, "#bulk-action-panel button", "Retry failed rows")

  # The submit form hides its file input while a sheet is uploaded, so a
  # refused sheet never replaces a good one there: "Clear" comes first.
  describe "the submit upload" do
    for {kind, {content, message}} <- @refusals do
      test "refuses a #{kind} sheet and then takes a good one", %{conn: conn, super_user: user} do
        {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
        view = choose_region_create(view)

        html = upload_sheet(view, unquote(content))
        assert flash?(view, "Couldn't read regions.csv: " <> unquote(message))
        refute html =~ "rows uploaded"

        html = upload_sheet(view, to_csv(region_rows()))
        assert html =~ "2 rows uploaded"
        refute flash?(view, "Couldn't read regions.csv")
      end
    end
  end

  test "the submit upload refuses a file that isn't a readable spreadsheet", %{
    conn: conn,
    super_user: user
  } do
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

    view
    |> choose_region_create()
    |> file_input("#main_form", :sheet, [
      %{name: "regions.xlsx", content: "not a workbook", type: "application/octet-stream"}
    ])
    |> render_upload("regions.xlsx")

    assert flash?(view, "Couldn't read regions.xlsx: it isn't a readable spreadsheet or CSV.")
  end

  describe "the retry upload" do
    for {kind, {content, message}} <- @refusals do
      test "refuses a #{kind} sheet in place of a good one, disabling Retry, then takes a good one",
           %{conn: conn, super_user: user} do
        {view, bulk_action, second} = parked_bulk_action(conn, user)

        [failed] =
          Row
          |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
          |> Ash.read!(authorize?: false)
          |> Enum.filter(&(&1.status == :failed))

        corrected = "row_id,last_error,code\n#{failed.id},,#{second.code}\n"

        upload_retry(view, corrected)
        assert staged?(view)
        refute retry_disabled?(view)

        upload_retry(view, unquote(content))
        assert flash?(view, "Couldn't read corrections.csv: " <> unquote(message))
        refute staged?(view)
        assert retry_disabled?(view)

        upload_retry(view, corrected)
        refute flash?(view, "Couldn't read corrections.csv")
        refute retry_disabled?(view)

        retry_button(view) |> render_click()
        assert 1 = Worker.drain()

        assert Ash.get!(BulkAction, bulk_action.id, authorize?: false).status == :completed
      end
    end
  end
end
