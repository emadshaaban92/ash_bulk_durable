defmodule ExampleWeb.Scenarios.BulkTenantColumnScenarioTest do
  @moduledoc """
  A sheet whose column names each row's tenant, corrected on `/bulk`: a
  mistyped workspace fails that row alone, on the panel, and the owner uploads
  the errors sheet with the cell fixed and the row runs in the right one.

  `/bulk`'s form has no card for such a column, so the sheet is staged through
  the facade; the panel, the upload and the retry are the page's. `Widget` is
  multitenant by workspace, its tables created inside the sandbox transaction.
  """
  use ExampleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AshBulkDurable.Sheet
  alias Example.Test.{Widget, Workspace}
  alias Example.BulkActions.BulkAction

  @moduletag :scenario

  setup do
    Example.Repo.query!(
      "CREATE TABLE bulk_tenant_test_workspaces (id uuid PRIMARY KEY, code text NOT NULL)"
    )

    Example.Repo.query!("""
    CREATE TABLE bulk_tenant_test_widgets (
      id uuid PRIMARY KEY,
      workspace_id uuid NOT NULL,
      name text NOT NULL,
      parent_id uuid
    )
    """)

    %{
      north: Ash.create!(Workspace, %{code: "NORTH"}),
      south: Ash.create!(Workspace, %{code: "SOUTH"})
    }
  end

  test "a mistyped workspace fails its row on the panel, and the corrected sheet runs it there",
       %{conn: conn, super_user: user, north: north, south: south} do
    {:ok, bulk_action} =
      %Sheet{
        headers: ["Name", "Workspace"],
        rows: [
          %{"Name" => "kept", "Workspace" => "NORTH"},
          %{"Name" => "moved", "Workspace" => "SOTUH"}
        ]
      }
      |> AshBulkDurable.bulk_create(Widget, :create,
        scope: Example.Scope.new(actor: user),
        mapping: [
          columns: %{name: "Name"},
          tenant_mapping: %{resource: Workspace, identity: :code, csv_col: "Workspace"}
        ]
      )

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    html = render(view)
    assert html =~ "1 of 2 rows done"
    assert html =~ "SOTUH"

    bulk_action = Ash.get!(BulkAction, bulk_action.id, authorize?: false)
    errors = AshBulkDurable.errors_sheet(bulk_action)
    assert [%{"tenant.code" => "SOTUH"} = cells] = errors.rows

    view
    |> file_input("#retry-upload-form", :retry_csv, [
      %{
        name: "corrections.csv",
        content:
          %{errors | rows: [%{cells | "tenant.code" => "SOUTH"}]}
          |> Sheet.to_csv()
          |> Enum.join(),
        type: "text/csv"
      }
    ])
    |> render_upload("corrections.csv")

    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)

    assert render(view) =~ "2 of 2 rows done"
    assert names(north) == ["kept"]
    assert names(south) == ["moved"]
  end

  defp names(workspace),
    do: Widget |> Ash.read!(tenant: workspace.id) |> Enum.map(& &1.name)
end
