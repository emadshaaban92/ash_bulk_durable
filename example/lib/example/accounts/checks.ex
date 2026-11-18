defmodule Example.Accounts.Checks.ActorIsSuperUser do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a super user"

  @impl true
  def match?(%{platform_roles: roles}, _context, _opts), do: :super_user in roles
  def match?(_actor, _context, _opts), do: false
end

defmodule Example.Accounts.Checks.ActorHasPlatformRole do
  @moduledoc "A super user holds every platform role."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor has platform role #{inspect(opts[:role])}"

  @impl true
  def match?(%{platform_roles: roles}, _context, opts),
    do: :super_user in roles or opts[:role] in roles

  def match?(_actor, _context, _opts), do: false
end

defmodule Example.Accounts.Checks.ActorHasOrganizationRole do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor has organization role #{inspect(opts[:role])}"

  @impl true
  def match?(%{organization_roles: roles}, _context, opts) when is_list(roles),
    do: opts[:role] in roles

  def match?(_actor, _context, _opts), do: false
end

defmodule Example.Accounts.Checks.ChangingPlatformRoles do
  @moduledoc """
  True when a write would leave a user with platform roles other than the
  ones they hold. A new user holds none, so creating one with none is no
  change.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "changing platform roles"

  @impl true
  def match?(_actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    roles = Ash.Changeset.get_attribute(changeset, :platform_roles) || []
    Enum.sort(roles) != Enum.sort(changeset.data.platform_roles || [])
  end

  def match?(_actor, _context, _opts), do: false
end
