defmodule Example.Accounts.MemberOfOrganization do
  @moduledoc """
  A user acts only in an organization they belong to, with no roles there but
  the ones their membership holds; a super user acts in any. Checked when a
  user's organization or roles change, so no one is placed where their bulk
  actions would then be refused (`Example.BulkActions.Owner`), and no one
  claims, on the user policies read, a role their membership doesn't give.
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias Example.Accounts.Membership

  @impl true
  def validate(changeset, _opts, _context) do
    organization_id = Ash.Changeset.get_attribute(changeset, :organization_id)
    platform_roles = Ash.Changeset.get_attribute(changeset, :platform_roles) || []
    organization_roles = Ash.Changeset.get_attribute(changeset, :organization_roles) || []

    cond do
      not changing?(changeset) or :super_user in platform_roles ->
        :ok

      is_nil(organization_id) ->
        held_roles(organization_roles, [])

      roles = membership_roles(changeset.data.id, organization_id) ->
        held_roles(organization_roles, roles)

      true ->
        {:error, field: :organization_id, message: "is not an organization the user belongs to"}
    end
  end

  defp held_roles(roles, held) do
    if roles -- held == [],
      do: :ok,
      else: {:error, field: :organization_roles, message: "are not roles the user holds there"}
  end

  defp changing?(changeset),
    do:
      Enum.any?(
        [:organization_id, :platform_roles, :organization_roles],
        &Ash.Changeset.changing_attribute?(changeset, &1)
      )

  @doc "The roles `user_id`'s membership holds at `organization_id`, or nil with none."
  # `Ash.can?` with no record builds `change_tenant` over an empty user.
  def membership_roles(nil, _organization_id), do: nil
  def membership_roles(_user_id, nil), do: nil

  def membership_roles(user_id, organization_id) do
    Membership
    |> Ash.Query.filter(user_id == ^user_id and organization_id == ^organization_id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> nil
      membership -> membership.roles
    end
  end
end
