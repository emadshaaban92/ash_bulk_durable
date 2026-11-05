defmodule AshBulkDurable.Test.Checks.ActorIsSuperUser do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a super user"

  @impl true
  def match?(%{platform_roles: roles}, _context, _opts), do: :super_user in roles
  def match?(_actor, _context, _opts), do: false
end

defmodule AshBulkDurable.Test.Checks.ActorHasPlatformRole do
  @moduledoc "A super user holds every platform role."
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor has platform role #{inspect(opts[:role])}"

  @impl true
  def match?(%{platform_roles: roles}, _context, opts),
    do: :super_user in roles or opts[:role] in roles

  def match?(_actor, _context, _opts), do: false
end

defmodule AshBulkDurable.Test.Checks.ActorHasOrganizationRole do
  @moduledoc false
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor has organization role #{inspect(opts[:role])}"

  @impl true
  def match?(%{organization_roles: roles}, _context, opts) when is_list(roles),
    do: opts[:role] in roles

  def match?(_actor, _context, _opts), do: false
end
