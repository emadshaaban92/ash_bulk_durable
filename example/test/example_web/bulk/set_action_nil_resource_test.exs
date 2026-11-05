defmodule ExampleWeb.Bulk.SetActionNilResourceTest do
  @moduledoc """
  A handcrafted `/bulk?resource=X&action=Y` URL where the actor can reach
  `/bulk` but cannot write resource `X`: the resource stays unresolved, and
  `ViewOptions.set_action/2` must render the empty picker, not crash.

  A clerk can navigate to `/bulk` but cannot import bookings.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.RoleTestHelpers

  test "handcrafted ?resource=booking&action=import renders cleanly for a role that can't import",
       %{conn: conn, super_user: super_user} do
    organization = RoleTestHelpers.create_organization(super_user)

    clerk = RoleTestHelpers.create_user_with_organization_role(super_user, organization, [:clerk])

    conn
    |> login_as(clerk)
    |> visit(~p"/bulk?resource=booking&action=import")
    |> assert_has("label", text: "Resource")
    # Booking never resolves for this actor, so no field cards render.
    |> refute_has("label", text: "Asset")
  end
end
