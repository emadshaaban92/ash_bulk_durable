defmodule Example.Test.RoleTestHelpers do
  @moduledoc "Users holding roles, and the organizations they hold them at."
  alias Example.Accounts.{Membership, Organization, User}

  def create_organization(_super_user) do
    tag = System.unique_integer([:positive])
    Ash.create!(Organization, %{code: "O#{tag}", name: "Organization #{tag}"}, authorize?: false)
  end

  def create_user_with_platform_role(_super_user, role) do
    Ash.create!(User, user_input(%{platform_roles: [role]}), authorize?: false)
  end

  def create_user_with_organization_role(_super_user, organization, roles) when is_list(roles) do
    user = Ash.create!(User, user_input(%{}), authorize?: false)

    Ash.create!(Membership, %{user_id: user.id, organization_id: organization.id, roles: roles})

    Ash.update!(user, %{organization_id: organization.id, organization_roles: roles},
      authorize?: false
    )
  end

  @doc "A user holding roles at each of `memberships`, acting for the first."
  def create_user_with_organization_roles(_super_user, [{first, roles} | _rest] = memberships) do
    user = Ash.create!(User, user_input(%{}), authorize?: false)

    for {organization, roles} <- memberships do
      Ash.create!(Membership, %{user_id: user.id, organization_id: organization.id, roles: roles})
    end

    Ash.update!(user, %{organization_id: first.id, organization_roles: roles}, authorize?: false)
  end

  defp user_input(input) do
    tag = System.unique_integer([:positive])
    Map.merge(%{name: "User #{tag}", email: "user#{tag}@example.test"}, input)
  end
end
