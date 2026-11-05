defmodule Example.Test.Workspace do
  @moduledoc """
  The tenant `Example.Test.Widget` is scoped by. Test-only: no
  migration creates its table; `AshBulkDurable.Core.TenantTest` creates it
  inside its sandbox transaction.
  """
  use Ash.Resource, domain: Example.Test.Domain, data_layer: AshPostgres.DataLayer

  postgres do
    table "bulk_tenant_test_workspaces"
    repo Example.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, create: [:code]]
  end
end

defmodule Example.Test.Widget do
  @moduledoc """
  A resource multitenant by attribute, the shape the bulk engine's per-row
  tenants serve. Test-only, like
  `Example.Test.Workspace`.
  """
  use Ash.Resource, domain: Example.Test.Domain, data_layer: AshPostgres.DataLayer

  multitenancy do
    strategy :attribute
    attribute :workspace_id
  end

  postgres do
    table "bulk_tenant_test_widgets"
    repo Example.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :workspace_id, :uuid, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :parent_id, :uuid, public?: true
  end

  identities do
    identity :name, [:name]
  end

  actions do
    defaults [:read, create: [:name, :parent_id], update: [:name, :parent_id]]
  end
end

defmodule Example.Test.Gadget do
  @moduledoc """
  A resource multitenant by context: no attribute holds its tenant, so a
  record knows it only from where it was read. Test-only, on ETS.
  """
  use Ash.Resource, domain: Example.Test.Domain, data_layer: Ash.DataLayer.Ets

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, create: [:name], update: [:name]]
  end
end
