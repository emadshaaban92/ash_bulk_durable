defmodule AshBulkDurable.Test.Owner do
  @moduledoc """
  A bulk action belongs to the user who submitted it, kept by id; the worker
  acts as that user as they are when it runs, in the organization they
  submitted it from.
  """
  @behaviour AshBulkDurable.Core.Owner

  alias AshBulkDurable.Test.{Scope, User}

  @impl true
  def worker_key(%Scope{current_user: %{id: id}}), do: id

  @impl true
  def scope_from_worker_key(user_id, organization_id) when is_binary(user_id) do
    case Ash.get!(User, user_id, authorize?: false, load: [:memberships], not_found_error?: false) do
      nil -> {:error, :user_not_found}
      user -> acting_in(user, organization_id)
    end
  end

  # Policies read the actor's organization and roles, so the tenant alone would
  # leave them on the organization the user has moved to. One who has left the
  # organization they submitted from is refused: every row naming no tenant
  # of its own is written in it whatever the scope says.
  defp acting_in(user, organization_id) do
    memberships = Enum.filter(user.memberships, &(&1.organization_id == organization_id))

    if is_nil(organization_id) or memberships != [] or :super_user in user.platform_roles do
      {:ok,
       Scope.new(
         actor: %{
           user
           | organization_id: organization_id,
             organization_roles: Enum.flat_map(memberships, & &1.roles)
         }
       )}
    else
      {:error, :not_a_member}
    end
  end
end
