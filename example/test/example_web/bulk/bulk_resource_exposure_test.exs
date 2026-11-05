defmodule ExampleWeb.Bulk.BulkResourceExposureTest do
  @moduledoc """
  What `/bulk` offers to run on is the resources it is configured for, and of
  those whatever the actor's policies let them create or update. It is listed
  by resource rather than by domain because a domain also holds what no bulk
  action should touch.

  A membership is what grants a role, so writing one by sheet is granting
  yourself one. It isn't listed, and it is refused to everyone, from the picker
  and from a hand-built URL alike.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.RoleTestHelpers

  test "no role is offered memberships", %{conn: conn, super_user: super_user} do
    organization = RoleTestHelpers.create_organization(super_user)

    clerk = RoleTestHelpers.create_user_with_organization_role(super_user, organization, [:clerk])

    for user <- [clerk, super_user] do
      conn
      |> login_as(user)
      |> visit(~p"/bulk")
      |> assert_has("option", text: "Book")
      |> refute_has("option", text: "Membership")

      # Naming it in the URL resolves to nothing rather than a mapping form.
      conn
      |> login_as(user)
      |> visit(~p"/bulk?resource=membership&action=create")
      |> refute_has("label", text: "Roles")
    end
  end

  test "only the resources /bulk is built for are offered, not the rest of their domain",
       %{conn: conn, super_user: super_user} do
    session = conn |> login_as(super_user) |> visit(~p"/bulk")

    for offered <- ["Book", "Author", "Organization", "Region", "Branch"] do
      assert_has(session, "option", text: offered, exact: true)
    end

    for withheld <- ["Membership", "Workspace", "Bulk action"] do
      refute_has(session, "option", text: withheld, exact: true)
    end
  end
end
