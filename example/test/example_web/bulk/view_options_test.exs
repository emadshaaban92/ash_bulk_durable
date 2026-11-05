defmodule ExampleWeb.Bulk.ViewOptionsTest do
  @moduledoc """
  Branch coverage for the small handful of pure helpers in `ExampleWeb.Bulk.ViewOptions`
  that drive how each `FieldMappingPanel` card is labelled and gated:

    * `required?/2` — the per-field "must the user supply this?" rule
      that combines action type, identity keys, arguments and defaults.
    * `belongs_to?/1` and the companion-upload accessors.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Sheet.Mapping
  alias ExampleWeb.Bulk.ViewOptions
  alias Example.Test.Region
  alias Example.Test.RegionPin

  defp opts(action_name, identity_name \\ nil) do
    %ViewOptions{
      resource: Region,
      action: Ash.Resource.Info.action(Region, action_name),
      identity: identity_name && Ash.Resource.Info.identity(Region, identity_name)
    }
  end

  defp field(action_name, name) do
    %AshBulkDurable.Sheet.Field{
      field: Ash.Resource.Info.attribute(Region, name),
      resource: Region,
      action: Ash.Resource.Info.action(Region, action_name)
    }
  end

  defp argument(allow_nil?, default \\ nil) do
    %AshBulkDurable.Sheet.Field{
      field: %Ash.Resource.Actions.Argument{
        name: :reason,
        type: Ash.Type.String,
        allow_nil?: allow_nil?,
        default: default
      },
      resource: Region,
      action: Ash.Resource.Info.action(Region, :update)
    }
  end

  describe "required?/2 — :create attributes" do
    test "attribute with allow_nil?: false is required" do
      assert ViewOptions.required?(field(:create, :name), opts(:create))
      assert ViewOptions.required?(field(:create, :code), opts(:create))
    end

    test "primary key with an Ash-generated default is not required" do
      # `uuid_v7_primary_key/1` sets `allow_nil?: false` AND a default
      # generator — the default short-circuits the required check.
      refute ViewOptions.required?(field(:create, :id), opts(:create))
    end

    test "timestamp attributes are not required (defaults fill them in)" do
      refute ViewOptions.required?(field(:create, :inserted_at), opts(:create))
      refute ViewOptions.required?(field(:create, :updated_at), opts(:create))
    end
  end

  describe "required?/2 — :update attributes" do
    test "non-identity attribute is not required even when allow_nil?: false" do
      # The DB constraint is already satisfied by the existing row; on
      # update the user maps only the subset they want to change.
      refute ViewOptions.required?(field(:update, :name), opts(:update, :code))
      refute ViewOptions.required?(field(:update, :native_name), opts(:update, :code))
    end

    test "identity key is required (it's how we look up the row)" do
      assert ViewOptions.required?(field(:update, :code), opts(:update, :code))
    end

    test "non-identity-key attributes stay optional regardless of which identity is chosen" do
      refute ViewOptions.required?(field(:update, :name), opts(:update, :code))
      assert ViewOptions.required?(field(:update, :name), opts(:update, :name))
    end
  end

  describe "required?/2 — arguments" do
    test "argument with allow_nil?: false is required" do
      assert ViewOptions.required?(argument(false), opts(:update, :code))
    end

    test "argument with allow_nil?: true is not required" do
      refute ViewOptions.required?(argument(true), opts(:update, :code))
    end

    test "argument with a non-nil default is not required even if allow_nil?: false" do
      refute ViewOptions.required?(argument(false, "no reason given"), opts(:update, :code))
    end
  end

  describe "belongs_to?/1" do
    test "true for belongs_to relationship fields" do
      bf = %AshBulkDurable.Sheet.Field{
        field: %Ash.Resource.Relationships.BelongsTo{name: :parent, allow_nil?: false},
        resource: Region,
        action: Ash.Resource.Info.action(Region, :create)
      }

      assert ViewOptions.belongs_to?(bf)
    end

    test "false for plain attributes" do
      refute ViewOptions.belongs_to?(field(:create, :name))
    end
  end

  describe "cross_tenant?/1" do
    alias Example.Test.OrganizationScoped
    alias Example.Scope

    defp scoped_opts(action_name, identity_name, scope) do
      %ViewOptions{
        scope: scope,
        resource: OrganizationScoped,
        action: Ash.Resource.Info.action(OrganizationScoped, action_name),
        identity: identity_name && Ash.Resource.Info.identity(OrganizationScoped, identity_name)
      }
    end

    defp scope_without_tenant, do: %Scope{current_user: nil, tenant: nil}
    defp scope_with_tenant, do: %Scope{current_user: nil, tenant: Ecto.UUID.generate()}

    test "true when all four conditions hold (multi-tenant + global, :update, no scope tenant, per-tenant identity)" do
      assert ViewOptions.cross_tenant?(scoped_opts(:update, :code, scope_without_tenant()))
    end

    test "false when scope has a tenant set" do
      refute ViewOptions.cross_tenant?(scoped_opts(:update, :code, scope_with_tenant()))
    end

    test "false for non-update actions (e.g. :create)" do
      # OrganizationScoped.create is the primary :create
      create = Ash.Resource.Info.action(OrganizationScoped, :create)

      opts = %ViewOptions{
        scope: scope_without_tenant(),
        resource: OrganizationScoped,
        action: create,
        identity: Ash.Resource.Info.identity(OrganizationScoped, :code)
      }

      refute ViewOptions.cross_tenant?(opts)
    end

    test "false on a non-multi-tenant resource (Region)" do
      opts = %ViewOptions{
        scope: scope_without_tenant(),
        resource: Region,
        action: Ash.Resource.Info.action(Region, :update),
        identity: Ash.Resource.Info.identity(Region, :code)
      }

      refute ViewOptions.cross_tenant?(opts)
    end
  end

  describe "tenant_rel/1 + tenant_mapping_for_persist/1" do
    alias Example.Test.OrganizationScoped
    alias Example.Scope

    defp cross_tenant_opts_for_scoped do
      %ViewOptions{
        scope: %Scope{current_user: nil, tenant: nil},
        resource: OrganizationScoped,
        action: Ash.Resource.Info.action(OrganizationScoped, :update),
        identity: Ash.Resource.Info.identity(OrganizationScoped, :code),
        mapping: %{organization: "Organization Name"},
        rel_identities: %{organization: :name}
      }
    end

    test "tenant_rel/1 returns the belongs_to :organization relationship when cross-tenant" do
      rel = ViewOptions.tenant_rel(cross_tenant_opts_for_scoped())

      assert %Ash.Resource.Relationships.BelongsTo{
               name: :organization,
               source_attribute: :organization_id
             } =
               rel
    end

    test "tenant_rel/1 returns nil when not cross-tenant (Region)" do
      opts = %ViewOptions{
        scope: %Scope{current_user: nil, tenant: nil},
        resource: Region,
        action: Ash.Resource.Info.action(Region, :update),
        identity: Ash.Resource.Info.identity(Region, :code)
      }

      assert is_nil(ViewOptions.tenant_rel(opts))
    end

    test "tenant_mapping_for_persist/1 returns the persisted shape when both identity + column are set" do
      assert %{rel_name: :organization, identity: :name, csv_col: "Organization Name"} =
               ViewOptions.tenant_mapping_for_persist(cross_tenant_opts_for_scoped())
    end

    test "tenant_mapping_for_persist/1 returns nil when the organization card is incomplete" do
      opts = cross_tenant_opts_for_scoped() |> Map.put(:rel_identities, %{})
      assert is_nil(ViewOptions.tenant_mapping_for_persist(opts))

      opts = cross_tenant_opts_for_scoped() |> Map.put(:mapping, %{})
      assert is_nil(ViewOptions.tenant_mapping_for_persist(opts))
    end

    test "tenant_mapping_for_persist/1 returns nil when not cross-tenant" do
      opts = %ViewOptions{
        scope: %Scope{current_user: nil, tenant: nil},
        resource: Region,
        action: Ash.Resource.Info.action(Region, :update),
        identity: Ash.Resource.Info.identity(Region, :code),
        mapping: %{},
        rel_identities: %{}
      }

      assert is_nil(ViewOptions.tenant_mapping_for_persist(opts))
    end
  end

  describe "partition_fields/1" do
    alias Example.Test.OrganizationScoped
    alias Example.Scope

    test "splits update fields into {identity, other} so the panel can label them" do
      opts = %ViewOptions{
        scope: %Scope{current_user: nil, tenant: Ecto.UUID.generate()},
        resource: Region,
        action: Ash.Resource.Info.action(Region, :update),
        identity: Ash.Resource.Info.identity(Region, :code)
      }

      {identity, other} = ViewOptions.partition_fields(opts)
      identity_names = Enum.map(identity, & &1.field.name)
      other_names = Enum.map(other, & &1.field.name)

      assert :code in identity_names
      refute :name in identity_names
      assert :name in other_names
    end

    test "cross-tenant mode: the synthetic Organization card lands in the identity group" do
      opts = %ViewOptions{
        scope: %Scope{current_user: nil, tenant: nil},
        resource: OrganizationScoped,
        action: Ash.Resource.Info.action(OrganizationScoped, :update),
        identity: Ash.Resource.Info.identity(OrganizationScoped, :code)
      }

      {identity, _other} = ViewOptions.partition_fields(opts)
      identity_names = Enum.map(identity, & &1.field.name)

      assert :code in identity_names
      assert :organization in identity_names
    end

    test "create actions have no identity group" do
      opts = %ViewOptions{
        scope: %Scope{current_user: nil, tenant: Ecto.UUID.generate()},
        resource: Region,
        action: Ash.Resource.Info.action(Region, :create),
        identity: nil
      }

      {identity, other} = ViewOptions.partition_fields(opts)
      assert identity == []
      assert Enum.any?(other, &(&1.field.name == :name))
    end
  end

  # URL params are user-controllable strings. A handcrafted
  # `?resource=nope` used to crash the LV with `ArgumentError` from
  # `String.to_existing_atom/1`; the setters now treat an unknown atom as
  # "leave unselected" so the LV survives malformed deep links.
  describe "an identity's keys" do
    test "a key on a belongs_to stays that key's own card, and maps to the row's lookup" do
      opts = %ViewOptions{
        resource: RegionPin,
        action: Ash.Resource.Info.action(RegionPin, :update),
        identity: Ash.Resource.Info.identity(RegionPin, :region),
        mapping: %{region_id: "region"}
      }

      assert {[%{field: %{name: :region_id}} = key], _others} = ViewOptions.partition_fields(opts)
      assert ViewOptions.required?(key, opts)

      mapping = %Mapping{
        resource: RegionPin,
        action: opts.action,
        identity: opts.identity,
        columns: opts.mapping
      }

      assert {:ok, [%{target: %{lookup: %{region_id: "L1"}}}]} =
               Mapping.rows(
                 mapping,
                 [%{"region" => "L1"}],
                 %AshBulkDurable.Sheet.PrepareContext{}
               )
    end

    test "the primary key is one across tenants, so it asks for no organization card" do
      opts =
        cross_tenant_opts_for_scoped()
        |> Map.put(
          :identity,
          Mapping.lookup_identity(Example.Test.OrganizationScoped, :primary_key)
        )

      refute ViewOptions.cross_tenant?(opts)

      assert %{field: %{name: :id}} =
               opts |> ViewOptions.fields() |> Enum.find(&(&1.field.name == :id))
    end
  end

  describe "URL atom rescue" do
    defp allowed_region_opts do
      %ViewOptions{
        allowed_resources: %{Region => Ash.Resource.Info.actions(Region)}
      }
    end

    test "set_resource/2 with an unknown atom name leaves resource nil" do
      opts =
        allowed_region_opts()
        |> ViewOptions.set_resource("definitely-not-a-real-resource-name")

      assert is_nil(opts.resource)
    end

    test "set_action/2 with an unknown atom name leaves action nil, resource intact" do
      opts =
        allowed_region_opts()
        |> ViewOptions.set_resource("region")
        |> ViewOptions.set_action("warp-drive-engage")

      assert opts.resource == Region
      assert is_nil(opts.action)
    end

    test "set_identity/2 with an unknown atom name leaves identity nil" do
      opts =
        allowed_region_opts()
        |> ViewOptions.set_resource("region")
        |> ViewOptions.set_action("update")
        |> ViewOptions.set_identity("not-a-real-identity")

      assert opts.resource == Region
      assert is_nil(opts.identity)
    end

    test "update_mapping/3 with an unknown field-name string is a no-op" do
      opts = allowed_region_opts() |> ViewOptions.set_resource("region")
      result = ViewOptions.update_mapping(opts, "not-a-field-name-string", "csv_col")

      assert result.mapping == opts.mapping
    end

    test "update_rel_identities/3 with an unknown identity-name string deletes the entry" do
      opts =
        %{
          allowed_region_opts()
          | rel_identities: %{organization: :name}
        }
        |> ViewOptions.update_rel_identities(:organization, "no-such-identity-name")

      refute Map.has_key?(opts.rel_identities, :organization)
    end
  end

  describe "cross-tenant Organization card surfaces in fields/1" do
    alias Example.Test.OrganizationScoped
    alias Example.Scope

    test "in cross-tenant mode the synthetic belongs_to :organization field appears" do
      opts = %ViewOptions{
        scope: %Scope{current_user: nil, tenant: nil},
        resource: OrganizationScoped,
        action: Ash.Resource.Info.action(OrganizationScoped, :update),
        identity: Ash.Resource.Info.identity(OrganizationScoped, :code)
      }

      fields = ViewOptions.fields(opts)
      organization_field = Enum.find(fields, &match?(%{field: %{name: :organization}}, &1))

      assert organization_field
      assert ViewOptions.belongs_to?(organization_field)
      assert ViewOptions.required?(organization_field, opts)
    end

    test "with scope tenant set, no Organization card appears (single-tenant mode)" do
      opts = %ViewOptions{
        scope: %Scope{current_user: nil, tenant: Ecto.UUID.generate()},
        resource: OrganizationScoped,
        action: Ash.Resource.Info.action(OrganizationScoped, :update),
        identity: Ash.Resource.Info.identity(OrganizationScoped, :code)
      }

      fields = ViewOptions.fields(opts)
      refute Enum.any?(fields, &match?(%{field: %{name: :organization}}, &1))
    end
  end
end
