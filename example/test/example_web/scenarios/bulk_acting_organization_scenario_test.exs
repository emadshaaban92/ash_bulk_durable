defmodule ExampleWeb.Scenarios.BulkActingOrganizationScenarioTest do
  @moduledoc """
  A bulk action acts where its owner acted when submitting it: the worker
  reads and writes in that organization, holding the owner's roles there, as
  the owner's own pages did, wherever the owner has switched to since. People
  are updated by sheet, by email, one in the owner's organization and one in
  another; only the first is found. Multitenancy reaches a user here through
  `User`, the one resource attribute-multitenant by organization.
  """
  use ExampleWeb.FeatureCase, async: true

  import Phoenix.LiveViewTest, only: [file_input: 4, render_upload: 2]

  require Ash.Query

  alias Example.BulkActions.BulkAction
  alias Example.Accounts.{Membership, User}
  alias Example.Test.RoleTestHelpers

  @moduletag :scenario

  setup %{super_user: super_user} do
    organization = RoleTestHelpers.create_organization(super_user)
    other = RoleTestHelpers.create_organization(super_user)

    %{
      organization: organization,
      other: other,
      here:
        RoleTestHelpers.create_user_with_organization_role(super_user, organization, [:inspector]),
      elsewhere:
        RoleTestHelpers.create_user_with_organization_role(super_user, other, [:inspector])
    }
  end

  test "a super user acting in one organization reaches only that organization's people",
       %{conn: conn, super_user: super_user, organization: organization} = context do
    acting =
      User.change_tenant!(super_user, organization.id, actor: super_user, authorize?: false)

    update_names(conn, acting, context)

    assert Ash.reload!(context.here, actor: super_user, authorize?: false).name == "Renamed here"

    assert Ash.reload!(context.elsewhere, actor: super_user, authorize?: false).name ==
             context.elsewhere.name
  end

  test "an organization admin reaches only their own organization's people",
       %{conn: conn, super_user: super_user, organization: organization} = context do
    admin =
      RoleTestHelpers.create_user_with_organization_role(super_user, organization, [
        :admin,
        :clerk
      ])

    update_names(conn, admin, context)

    assert Ash.reload!(context.here, actor: super_user, authorize?: false).name == "Renamed here"

    assert Ash.reload!(context.elsewhere, actor: super_user, authorize?: false).name ==
             context.elsewhere.name
  end

  test "a retry acts where the bulk action was submitted, not where its owner acts now",
       %{conn: conn, super_user: super_user, organization: organization, other: other} = context do
    acting =
      User.change_tenant!(super_user, organization.id, actor: super_user, authorize?: false)

    session = update_names(conn, acting, context)

    session
    |> switch_organization(acting, other.id)
    |> visit(~p"/bulk")
    |> retry_unchanged(acting)
    |> assert_has("*", text: "1 of 2 rows done", timeout: 2000)

    assert Ash.reload!(context.elsewhere, actor: super_user, authorize?: false).name ==
             context.elsewhere.name
  end

  test "a queued bulk action runs with the owner's roles where it was submitted",
       %{conn: conn, super_user: super_user, organization: organization, other: other} = context do
    # Only the organization it was submitted in lets this person rename anyone.
    owner =
      RoleTestHelpers.create_user_with_organization_roles(super_user, [
        {organization, [:admin, :clerk]},
        {other, [:clerk]}
      ])

    session =
      conn
      |> submit_names(owner, context)
      |> switch_organization(owner, other.id)

    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    session
    |> visit(~p"/bulk")
    |> assert_has("*", text: "1 of 2 rows done", timeout: 2000)

    assert Ash.reload!(context.here, actor: super_user, authorize?: false).name == "Renamed here"

    assert Ash.reload!(context.elsewhere, actor: super_user, authorize?: false).name ==
             context.elsewhere.name
  end

  test "an owner who has left the organization no longer acts in it",
       %{conn: conn, super_user: super_user, organization: organization, other: other} = context do
    owner =
      RoleTestHelpers.create_user_with_organization_roles(super_user, [
        {organization, [:admin, :clerk]},
        {other, [:clerk]}
      ])

    session =
      conn
      |> submit_names(owner, context)
      |> switch_organization(owner, other.id)

    Membership
    |> Ash.Query.filter(user_id == ^owner.id and organization_id == ^organization.id)
    |> Ash.read_one!(authorize?: false)
    |> Ash.destroy!(actor: super_user, authorize?: false)

    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    session
    |> visit(~p"/bulk")
    |> assert_has("*", text: "0 of 2 rows done", timeout: 2000)

    assert Ash.reload!(context.here, actor: super_user, authorize?: false).name ==
             context.here.name

    # Refused by the read, not only the write: they no longer see its people.
    assert errors_sheet(owner) =~ "could not be found,#{context.here.email}"
  end

  test "a super user acting in no organization keeps reaching every one after switching",
       %{conn: conn, super_user: super_user, organization: organization} = context do
    conn
    |> submit_names(super_user, context)
    |> switch_organization(super_user, organization.id)

    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    assert Ash.reload!(context.here, actor: super_user, authorize?: false).name == "Renamed here"

    assert Ash.reload!(context.elsewhere, actor: super_user, authorize?: false).name ==
             "Renamed elsewhere"
  end

  defp update_names(conn, actor, context) do
    session = submit_names(conn, actor, context)

    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    assert_has(session, "*", text: "1 of 2 rows done")
  end

  defp submit_names(conn, actor, %{here: here, elsewhere: elsewhere}) do
    {:ok, file_path} = Briefly.create(extname: ".csv")

    File.write!(file_path, """
    email,name
    #{here.email},Renamed here
    #{elsewhere.email},Renamed elsewhere
    """)

    conn
    |> login_as(actor)
    |> visit(~p"/bulk")
    |> select_change("Resource", option: "User")
    |> select_change("Action", option: "Update")
    |> select_change("Lookup by", option: "Email")
    |> within("#main_form", &upload(&1, "input[name='sheet']", "File", file_path))
    |> within("#field__email", &select_change(&1, "CSV column", option: "email"))
    |> within("#field__name", &select_change(&1, "CSV column", option: "name"))
    |> click_button("Submit")
    |> assert_has("#bulk-action-panel", timeout: 2000)
  end

  # An app's own tenant switcher, which this one has no screen for.
  defp switch_organization(session, actor, organization_id) do
    actor
    |> Ash.reload!(authorize?: false)
    |> User.change_tenant!(organization_id, actor: actor, authorize?: false)

    session
  end

  defp errors_sheet(owner) do
    BulkAction
    |> Ash.Query.filter(user_id == ^owner.id)
    |> Ash.read_one!(authorize?: false)
    |> ExampleWeb.Bulk.ErrorsSheet.build()
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  # The errors sheet as the panel serves it, sent back with nothing corrected.
  defp retry_unchanged(session, owner) do
    csv = errors_sheet(owner)

    session =
      session
      |> PhoenixTest.unwrap(fn view ->
        view
        |> file_input("#retry-upload-form", :retry_csv, [
          %{name: "corrections.csv", content: csv, type: "text/csv"}
        ])
        |> render_upload("corrections.csv")
      end)
      |> click_button("Retry failed rows")

    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    session
  end
end
