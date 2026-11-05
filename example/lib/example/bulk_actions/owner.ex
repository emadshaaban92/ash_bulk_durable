defmodule Example.BulkActions.Owner do
  @moduledoc """
  A bulk action belongs to the user who submitted it, kept by id; the worker
  acts as that user as they are when it runs, in the organization they
  submitted it from.
  """
  @behaviour AshBulkDurable.Core.Owner

  alias Example.Accounts.User
  alias Example.Scope

  @impl true
  def worker_key(%Scope{current_user: %{id: id}}), do: id

  @impl true
  def scope_from_worker_key(user_id, organization_id) when is_binary(user_id) do
    user = Ash.get!(User, user_id, authorize?: false, load: [:memberships])
    Scope.new(actor: acting_in(user, organization_id))
  end

  # Policies read the actor's organization and roles, so the tenant alone would
  # leave them on the organization the user has moved to.
  defp acting_in(user, organization_id) do
    memberships = Enum.filter(user.memberships, &(&1.organization_id == organization_id))

    %{
      user
      | organization_id: reachable(user, organization_id, memberships),
        organization_roles: Enum.flat_map(memberships, & &1.roles)
    }
  end

  defp reachable(%{platform_roles: roles}, organization_id, memberships) do
    cond do
      :super_user in roles -> organization_id
      memberships == [] -> nil
      true -> organization_id
    end
  end
end
