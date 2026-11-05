defmodule ExampleWeb.Scenarios.BulkPrimaryKeyScenarioTest do
  @moduledoc """
  `/bulk` finds a record by its primary key, on every resource. A booking has
  nothing else: both its identities are partial, so an order or an asset's key
  alone can match a cancelled booking too, and neither is offered.
  A key typed into a sheet can be mistyped, so unlike a selection's record it
  is corrected on the errors sheet.
  """
  use ExampleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Example.BulkActions.BulkAction
  alias Example.Test.{Booking, Region, RoleTestHelpers}

  @moduletag :scenario

  test "a booking is found by its primary key, not by a partial identity, and a mistyped one is corrected",
       %{conn: conn, super_user: super_user} do
    {:ok, view, _html} = conn |> login_as(super_user) |> live(~p"/bulk")
    choose(view, "booking", "refresh")

    identities = identity_options(view)
    assert "Primary key" in identities
    refute "Order" in identities
    refute "Active on asset" in identities

    # Forged past the dropdown, a partial identity is no choice at all.
    view
    |> element("#main_form select[name=identity_name]")
    |> render_change(%{"identity_name" => "order"})

    assert render(view) =~ "Select a lookup field above"
    refute has_element?(view, "#field__order")

    {:ok, view, _html} =
      conn
      |> login_as(super_user)
      |> live(~p"/bulk?resource=booking&action=refresh&identity=active_on_asset")

    refute has_element?(view, "#field__asset")
    assert render(view) =~ "Select a lookup field above"

    # A lookup named with no resource to look in is no lookup either.
    {:ok, view, _html} = conn |> login_as(super_user) |> live(~p"/bulk?identity=primary_key")
    refute has_element?(view, "#field__id")

    # The key is the lookup's own card, and it can't be left out.
    {:ok, view, _html} = conn |> login_as(super_user) |> live(~p"/bulk")
    choose(view, "booking", "refresh", "primary_key")
    assert view |> element("#field__id") |> render() =~ "Required"

    [found, mistyped] = [booking(super_user), booking(super_user)]

    wrong = Ash.UUIDv7.generate()
    bulk_action = submit(view, super_user, "id\n#{found.id}\n#{wrong}\n")
    assert %{success: 1, failure: 0} = drain()

    assert reload(bulk_action).status == :completed_with_errors
    assert render(view) =~ "1 of 2 rows done"

    assert Ash.reload!(found, authorize?: false).refreshed
    refute Ash.reload!(mistyped, authorize?: false).refreshed

    sheet = errors_sheet(bulk_action)
    assert sheet =~ wrong

    upload_correction(view, String.replace(sheet, wrong, mistyped.id))
    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
    assert %{success: 1, failure: 0} = drain()

    assert reload(bulk_action).status == :completed
    assert Ash.reload!(mistyped, authorize?: false).refreshed
  end

  test "an officer acts on their own organization's booking, and another's id finds nothing",
       %{conn: conn, super_user: super_user} do
    mine = RoleTestHelpers.create_organization(super_user)
    other = RoleTestHelpers.create_organization(super_user)
    own = booking(super_user, mine)
    theirs = booking(super_user, other)

    officer =
      RoleTestHelpers.create_user_with_organization_role(super_user, mine, [:clerk, :officer])

    {:ok, view, _html} = conn |> login_as(officer) |> live(~p"/bulk")
    choose(view, "booking", "release", "primary_key")
    bulk_action = submit(view, officer, "id\n#{own.id}\n#{theirs.id}\n")
    assert %{success: 1, failure: 0} = drain()

    assert reload(bulk_action).status == :completed_with_errors
    html = render(view)
    assert html =~ "1 of 2 rows done"
    # Not refused, which would say the booking exists: it isn't theirs to find.
    assert html =~ "could not be found"

    assert Ash.reload!(own, authorize?: false).status == :cancelled
    assert Ash.reload!(theirs, authorize?: false).status == :active

    # Without the officer's role the action isn't there to choose.
    clerk = RoleTestHelpers.create_user_with_organization_role(super_user, mine, [:clerk])

    {:ok, view, _html} = conn |> login_as(clerk) |> live(~p"/bulk?resource=booking")
    refute has_element?(view, "option[value=release]")
  end

  test "any resource takes its primary key: a blank or malformed cell finds nothing, and a destroy runs",
       %{conn: conn, super_user: super_user} do
    [first, second] = [region(super_user), region(super_user)]
    renamed = "Renamed #{System.unique_integer([:positive])}"

    {:ok, view, _html} = conn |> login_as(super_user) |> live(~p"/bulk")
    choose(view, "region", "update", "primary_key")
    assert view |> element("#field__id") |> render() =~ "Required"

    also_renamed = "Renamed #{System.unique_integer([:positive])}"

    csv =
      "id,name\n#{first.id},#{renamed}\nnot-a-key,Malformed\n,Blank\n#{second.id},#{also_renamed}\n"

    bulk_action = submit(view, super_user, csv)
    assert %{success: 1, failure: 0} = drain()

    assert reload(bulk_action).status == :completed_with_errors
    html = render(view)
    assert html =~ "2 of 4 rows done"
    assert html =~ "could not be found"
    refute html =~ "Ash.Query"
    refute html =~ "Ecto.Query"
    assert Ash.reload!(first, authorize?: false).name == renamed

    # A blank cell matched no record with no key, and neither row stays on
    # the sheet as anything but the key it typed.
    assert errors_sheet(bulk_action) =~ "not-a-key"
    assert Ash.get!(Region, second.id, authorize?: false).name == also_renamed

    view |> element("#bulk-action-panel button", "Abandon") |> render_click()

    {:ok, view, _html} = conn |> login_as(super_user) |> live(~p"/bulk")
    choose(view, "region", "destroy", "primary_key")
    destroyed = submit(view, super_user, "id\n#{second.id}\n")
    assert %{success: 1, failure: 0} = drain()

    assert reload(destroyed).status == :completed
    assert {:error, _gone} = Ash.get(Region, second.id, authorize?: false)
    assert Ash.get!(Region, first.id, authorize?: false)
  end

  test "all or nothing stops at the row whose key can't be one, and names it",
       %{conn: conn, super_user: super_user} do
    region = region(super_user)
    renamed = "Renamed #{System.unique_integer([:positive])}"

    {:ok, view, _html} = conn |> login_as(super_user) |> live(~p"/bulk")
    choose(view, "region", "update", "primary_key")

    bulk_action =
      submit(view, super_user, "id,name\n#{region.id},#{renamed}\nnot-a-key,Malformed\n", %{
        "all_or_nothing" => "on"
      })

    assert %{success: 1, failure: 0} = drain()

    assert reload(bulk_action).status == :failed
    html = render(view)
    assert html =~ "Row 2:"
    assert html =~ "could not be found"
    refute html =~ "Ash.Query"
    refute Ash.reload!(region, authorize?: false).name == renamed
  end

  defp choose(view, resource, action, identity \\ nil) do
    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => resource})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => action})

    if identity do
      view
      |> element("#main_form select[name=identity_name]")
      |> render_change(%{"identity_name" => identity})
    end

    view
  end

  defp identity_options(view) do
    view
    |> element("#main_form select[name=identity_name]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp submit(view, user, csv, form_params \\ %{}) do
    view
    |> file_input("#main_form", :sheet, [%{name: "sheet.csv", content: csv, type: "text/csv"}])
    |> render_upload("sheet.csv")

    view |> form("#main_form", form_params) |> render_submit()
    render_async(view, 2000)

    BulkAction
    |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user.id})
    |> Ash.read_one!(authorize?: false)
  end

  defp errors_sheet(bulk_action) do
    bulk_action |> ExampleWeb.Bulk.ErrorsSheet.build() |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp upload_correction(view, csv) do
    view
    |> file_input("#retry-upload-form", :retry_csv, [
      %{name: "corrections.csv", content: csv, type: "text/csv"}
    ])
    |> render_upload("corrections.csv")
  end

  defp booking(super_user, organization \\ nil) do
    Ash.create!(Booking, %{organization_id: organization && organization.id}, actor: super_user)
  end

  defp region(super_user) do
    tag = System.unique_integer([:positive])

    Ash.create!(
      Region,
      %{code: "G#{tag}", name: "Region #{tag}", native_name: "منطقة #{tag}"},
      actor: super_user
    )
  end

  defp reload(%BulkAction{id: id}),
    do: Ash.get!(BulkAction, id, authorize?: false, load: [:rows_done, :rows_pending])

  defp drain, do: AshBulkDurable.Core.Worker.drain()
end
