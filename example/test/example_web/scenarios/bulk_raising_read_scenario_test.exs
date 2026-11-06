defmodule ExampleWeb.Scenarios.BulkRaisingReadScenarioTest do
  @moduledoc """
  A refresh by sheet while one organization's upstream system is down: the
  read raises, and only that organization's rows pay for it. They fail on the
  panel in a sentence rather than the failure's own words, the rest of the
  sheet runs, and once the system is back the same rows retry. A bulk action
  asked all or nothing stops naming the row.

  Read on `/bulk` as the super user, who spans organizations, and as an
  organization's officer, who holds its own.

  `async: false`: the outage is application-wide.
  """
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshBulkDurable.Core.Worker
  alias Example.BulkActions.BulkAction
  alias Example.Test.{Booking, RoleTestHelpers}

  @moduletag :scenario

  @unexpected "This row hit an unexpected error, so nothing was saved for it."

  setup %{super_user: super_user} do
    %{
      up: RoleTestHelpers.create_organization(super_user),
      down: RoleTestHelpers.create_organization(super_user)
    }
  end

  test "the super user's sheet across organizations keeps going, and the failed row retries once the system is back",
       %{conn: conn, super_user: super_user, up: up, down: down} do
    [healthy, broken, also_healthy] = [
      booking(up, super_user),
      booking(down, super_user),
      booking(up, super_user)
    ]

    break_upstream(down)

    {view, bulk_action} = submit(conn, super_user, [healthy, broken, also_healthy])
    assert 1 = drain()

    fresh = reload(bulk_action)
    assert fresh.status == :completed_with_errors
    assert fresh.rows_done == 2

    html = render(view)
    assert html =~ "2 of 3 rows done"
    assert html =~ @unexpected
    refute html =~ "relation does not exist"
    refute html =~ "SELECT"

    repair_upstream()
    upload_sheet_unchanged(view, bulk_action)
    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
    assert 1 = drain()

    assert reload(bulk_action).status == :completed
    assert reload(bulk_action).rows_done == 3
  end

  test "the organization's officer reads the same failure on their own booking", %{
    conn: conn,
    super_user: super_user,
    down: down
  } do
    broken = booking(down, super_user)

    officer =
      RoleTestHelpers.create_user_with_organization_role(super_user, down, [:clerk, :officer])

    break_upstream(down)

    {view, bulk_action} = submit(conn, officer, [broken])
    assert 1 = drain()

    assert reload(bulk_action).status == :completed_with_errors
    assert render(view) =~ @unexpected
  end

  test "all or nothing stops naming the row that raised", %{
    conn: conn,
    super_user: super_user,
    up: up,
    down: down
  } do
    [healthy, broken] = [booking(up, super_user), booking(down, super_user)]
    break_upstream(down)

    {view, bulk_action} =
      submit(conn, super_user, [healthy, broken], %{"all_or_nothing" => "on"})

    assert 1 = drain()

    assert reload(bulk_action).status == :failed

    html = render(view)
    assert html =~ "A row failed, so the whole bulk action was rolled back"
    assert html =~ "Row 2: #{@unexpected}"
    refute html =~ "relation does not exist"
  end

  defp break_upstream(%{id: id}) do
    Application.put_env(:example, :upstream_down, [id])
    on_exit(&repair_upstream/0)
  end

  defp repair_upstream, do: Application.delete_env(:example, :upstream_down)

  defp booking(organization, super_user),
    do: Ash.create!(Booking, %{organization_id: organization.id}, actor: super_user)

  defp submit(conn, user, bookings, form_params \\ %{}) do
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => "booking"})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => "refresh"})

    view
    |> element("#main_form select[name=identity_name]")
    |> render_change(%{"identity_name" => "primary_key"})

    csv = Enum.map_join(bookings, "\n", & &1.id)

    view
    |> file_input("#main_form", :sheet, [
      %{name: "bookings.csv", content: "id\n#{csv}\n", type: "text/csv"}
    ])
    |> render_upload("bookings.csv")

    view |> form("#main_form", form_params) |> render_submit()
    render_async(view, 2000)

    bulk_action =
      BulkAction
      |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user.id})
      |> Ash.read_one!(authorize?: false)

    {view, bulk_action}
  end

  defp upload_sheet_unchanged(view, bulk_action) do
    csv =
      bulk_action
      |> ExampleWeb.Bulk.ErrorsSheet.build()
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    view
    |> file_input("#retry-upload-form", :retry_csv, [
      %{name: "corrections.csv", content: csv, type: "text/csv"}
    ])
    |> render_upload("corrections.csv")
  end

  defp reload(%BulkAction{id: id}), do: Ash.get!(BulkAction, id, authorize?: false)
  defp drain, do: Worker.drain()
end
