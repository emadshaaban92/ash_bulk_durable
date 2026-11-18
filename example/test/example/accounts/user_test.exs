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

  describe "organization roles" do
    setup ctx do
      # An admin at one organization and a clerk at the other.
      admin =
        RoleTestHelpers.create_user_with_organization_roles(nil, [
          {ctx.organization, [:admin]},
          {ctx.other, [:clerk]}
        ])

      %{admin: admin}
    end

    test "are only the ones a user's membership there holds", ctx do
      for {organization_id, roles} <- [{ctx.other.id, [:admin]}, {ctx.organization.id, [:owner]}] do
        assert {:error, %Ash.Error.Invalid{} = error} =
                 Ash.update(
                   ctx.admin,
                   %{organization_id: organization_id, organization_roles: roles},
                   actor: ctx.admin
                 )

        assert Exception.message(error) =~ "are not roles the user holds there"
      end
    end

    test "are none outside every organization", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(ctx.admin, %{organization_id: nil, organization_roles: [:admin]},
                 actor: ctx.admin
               )
    end

    test "change_tenant takes the ones held where the user moves", ctx do
      assert {:ok, %{organization_id: other_id, organization_roles: [:clerk]}} =
               User.change_tenant(ctx.admin, ctx.other.id, authorize?: false)

      assert other_id == ctx.other.id
    end
  end

  describe "platform roles" do
    setup ctx do
      admin = RoleTestHelpers.create_user_with_organization_role(nil, ctx.organization, [:admin])
      platform_admin = RoleTestHelpers.create_user_with_platform_role(nil, :platform_admin)
      super_user = RoleTestHelpers.create_user_with_platform_role(nil, :super_user)
      %{admin: admin, platform_admin: platform_admin, super_user: super_user}
    end

    test "an organization admin can't make themselves or anyone a super user", ctx do
      for target <- [ctx.admin, ctx.user] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Ash.update(target, %{platform_roles: [:super_user]}, actor: ctx.admin)
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(
                 User,
                 %{name: "N", email: unique_email(), platform_roles: [:super_user]},
                 actor: ctx.admin
               )
    end

    test "a platform admin can't make themselves a super user", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.update(ctx.platform_admin, %{platform_roles: [:super_user]},
                 actor: ctx.platform_admin
               )
    end

    test "an admin still writes the rest of a user, roles left as they are", ctx do
      assert {:ok, %{name: "Renamed"}} =
               Ash.update(ctx.user, %{name: "Renamed", platform_roles: []}, actor: ctx.admin)

      assert {:ok, %{platform_roles: []}} =
               Ash.create(User, %{name: "N", email: unique_email()}, actor: ctx.admin)

      # Roles a user already holds, sent back as they are, are no change.
      assert {:ok, %{name: "Renamed", platform_roles: [:platform_admin]}} =
               Ash.update(
                 ctx.platform_admin,
                 %{name: "Renamed", platform_roles: [:platform_admin]},
                 actor: ctx.platform_admin
               )
    end

    test "a super user changes them by hand", ctx do
      assert {:ok, %{platform_roles: [:platform_admin]}} =
               Ash.update(ctx.user, %{platform_roles: [:platform_admin]}, actor: ctx.super_user)
    end
  end

  # Email is unique across tenants, so async tests never share one.
  defp unique_email, do: "n#{System.unique_integer([:positive])}@example.test"
end
