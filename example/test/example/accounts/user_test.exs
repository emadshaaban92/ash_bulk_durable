defmodule Example.Accounts.UserTest do
  @moduledoc """
  A user is placed only in an organization they belong to, a super user in
  any, so a bulk action they submit there isn't refused when it runs.
  """
  use Example.DataCase, async: true

  require Ash.Query

  alias Example.Accounts.{Membership, User}
  alias Example.Test.RoleTestHelpers

  setup do
    organization = RoleTestHelpers.create_organization(nil)
    other = RoleTestHelpers.create_organization(nil)
    user = RoleTestHelpers.create_user_with_organization_role(nil, organization, [:clerk])
    %{organization: organization, other: other, user: user}
  end

  test ":update refuses an organization the user doesn't belong to", ctx do
    assert {:error, %Ash.Error.Invalid{} = error} =
             Ash.update(ctx.user, %{organization_id: ctx.other.id}, authorize?: false)

    assert Exception.message(error) =~ "is not an organization the user belongs to"
  end

  test "change_tenant refuses one too, and takes one they belong to", ctx do
    assert {:error, %Ash.Error.Invalid{}} =
             User.change_tenant(ctx.user, ctx.other.id, authorize?: false)

    Ash.create!(Membership, %{user_id: ctx.user.id, organization_id: ctx.other.id})

    assert {:ok, %{organization_id: other_id}} =
             User.change_tenant(ctx.user, ctx.other.id, authorize?: false)

    assert other_id == ctx.other.id
  end

  test "a super user is placed in any organization", ctx do
    super_user = RoleTestHelpers.create_user_with_platform_role(nil, :super_user)

    assert {:ok, %{organization_id: other_id}} =
             User.change_tenant(super_user, ctx.other.id, authorize?: false)

    assert other_id == ctx.other.id
  end

  test "losing super user while placed outside one's memberships is refused", ctx do
    super_user = RoleTestHelpers.create_user_with_platform_role(nil, :super_user)
    placed = User.change_tenant!(super_user, ctx.other.id, authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(placed, %{platform_roles: []}, authorize?: false)
  end

  test "an update that leaves the organization alone isn't checked", ctx do
    Ash.Query.filter(Membership, user_id == ^ctx.user.id)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false)

    assert {:ok, %{name: "Renamed"}} = Ash.update(ctx.user, %{name: "Renamed"}, authorize?: false)
  end
end
