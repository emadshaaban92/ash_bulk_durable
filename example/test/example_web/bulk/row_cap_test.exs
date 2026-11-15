defmodule ExampleWeb.Bulk.RowCapTest do
  @moduledoc """
  A sheet of more rows than `:max_rows`, uploaded on `/bulk`: refused at
  upload, saying so, rather than at submit.

  `async: false` — it lowers the global `:max_rows`.
  """
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.fetch_env(:ash_bulk_durable, :max_rows)
    Application.put_env(:ash_bulk_durable, :max_rows, 1)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_bulk_durable, :max_rows, value)
        :error -> Application.delete_env(:ash_bulk_durable, :max_rows)
      end
    end)
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

  test "a sheet over the cap is refused at upload; one at it is taken",
       %{conn: conn, super_user: user} do
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    view = choose_region_create(view)

    html = upload_sheet(view, "code,name\nA,Region A\nB,Region B\n")

    assert has_element?(
             view,
             "#flash-error",
             "Couldn't read regions.csv: it has more than 1 row. Split it into smaller files."
           )

    refute html =~ "rows uploaded"

    assert upload_sheet(view, "code,name\nA,Region A\n") =~ "1 row uploaded"
  end
end
