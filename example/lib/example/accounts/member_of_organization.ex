defmodule Example.Accounts.MemberOfOrganization do
  @moduledoc """
  A user acts only in an organization they belong to; a super user acts in
  any. Checked when a user's organization or platform roles change, so no one
  is placed where their bulk actions would then be refused
  (`Example.BulkActions.Owner`).
  """
  use Ash.Resource.Validation

  require Ash.Query

  alias Example.Accounts.Membership

  @impl true
  def validate(changeset, _opts, _context) do
    organization_id = Ash.Changeset.get_attribute(changeset, :organization_id)
    roles = Ash.Changeset.get_attribute(changeset, :platform_roles) || []

    cond do
      not changing?(changeset) ->
        :ok

      is_nil(organization_id) or :super_user in roles ->
        :ok

      member?(changeset.data.id, organization_id) ->
        :ok

      true ->
        {:error, field: :organization_id, message: "is not an organization the user belongs to"}
    end
  end

  defp changing?(changeset),
    do:
      Ash.Changeset.changing_attribute?(changeset, :organization_id) or
        Ash.Changeset.changing_attribute?(changeset, :platform_roles)

  defp member?(user_id, organization_id) do
    Membership
    |> Ash.Query.filter(user_id == ^user_id and organization_id == ^organization_id)
    |> Ash.exists?(authorize?: false)
  end
end
