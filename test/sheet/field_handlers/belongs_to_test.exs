defmodule AshBulkDurable.Sheet.FieldHandlers.BelongsToTest do
  @moduledoc """
  Unit tests for `AshBulkDurable.Sheet.FieldHandlers.BelongsTo`.

  `input_value/3` gives a `{:lookup, ...}` reference, which the core's
  runner resolves against the destination resource, so these tests need a
  sandboxed DB and a real `super_user` scope — `AshBulkDurable.DataCase` seeds
  both. With a stubbed lookup we'd lose coverage of the hit-vs-miss
  branching: a hit resolves to the related record's id, and a miss fails
  the row naming the relationship, the resource and the criteria.
  """
  use AshBulkDurable.DataCase, async: true

  alias AshBulkDurable.Sheet.Field
  alias AshBulkDurable.Sheet.FieldHandlers.BelongsTo
  alias AshBulkDurable.Core.Runner
  alias AshBulkDurable.Sheet.{PrepareContext, RowContext}
  alias AshBulkDurable.Test.Booking
  alias AshBulkDurable.Test.Region
  alias AshBulkDurable.Test.Asset
  alias AshBulkDurable.Test.Scope

  defp wrap(ash_field, resource, action_name) do
    %Field{
      field: ash_field,
      resource: resource,
      action: Ash.Resource.Info.action(resource, action_name)
    }
  end

  defp region_created_by_field do
    wrap(Ash.Resource.Info.relationship(Region, :inserted_by), Region, :create)
  end

  defp booking_asset_field do
    wrap(Ash.Resource.Info.relationship(Booking, :asset), Booking, :import)
  end

  defp ctx(opts) do
    %RowContext{
      row_index: 0,
      row: %{},
      scope: opts[:scope],
      state: opts[:state]
    }
  end

  # The runner resolving one row's input, as phase 1 does.
  defp resolve_input(field, input, scope) do
    settings = %Runner.Settings{
      resource: field.resource,
      action_name: field.action.name,
      action_type: field.action.type,
      scope: scope
    }

    row = %{input: input, resolved_data: %{}, row_index: 0, target: nil, resolved_tenant: nil}
    Runner.resolve_references(settings, row, %{})
  end

  # The handler's value for one cell, resolved as phase 1 does.
  defp resolve(field, cell, identity, scope) do
    key = field.field.source_attribute
    name = to_string(key)

    case BelongsTo.input_value(field, cell, ctx(scope: scope, state: %{identity: identity})) do
      {:ok, reference} ->
        case resolve_input(field, %{key => reference}, scope) do
          {:ok, %{^name => id}} -> {:ok, id}
          {:error, error} -> {:error, error}
        end

      :skip ->
        :nothing
    end
  end

  describe "handles?/1" do
    test "claims belongs_to relationships" do
      assert BelongsTo.handles?(region_created_by_field())
    end

    test "rejects plain attributes" do
      attr = Ash.Resource.Info.attribute(Region, :name)
      refute BelongsTo.handles?(wrap(attr, Region, :create))
    end

    test "rejects action arguments" do
      arg = %Ash.Resource.Actions.Argument{name: :foo, type: :string}
      refute BelongsTo.handles?(wrap(arg, Region, :create))
    end
  end

  describe "input_value/3 — single-key identity" do
    test "resolves to the related record's id when the lookup hits", %{super_user: super_user} do
      scope = Scope.new(actor: super_user)
      email = to_string(super_user.email)

      assert {:ok, {:lookup, AshBulkDurable.Test.User, :email, ^email}} =
               BelongsTo.input_value(
                 region_created_by_field(),
                 email,
                 ctx(scope: scope, state: %{identity: :email})
               )

      assert resolve(region_created_by_field(), email, :email, scope) ==
               {:ok, super_user.id}
    end

    test "fails the row naming the relationship, the resource and criteria when the lookup misses",
         %{super_user: super_user} do
      scope = Scope.new(actor: super_user)
      missing_email = "nobody-#{System.unique_integer([:positive])}@example.com"

      assert {:error, %{field: :inserted_by_id} = error} =
               resolve(region_created_by_field(), missing_email, :email, scope)

      message = Exception.message(error)
      assert message =~ "no User"
      assert message =~ "email"
      assert message =~ missing_email
    end

    test "sends nothing when no identity is set on ctx.state", %{super_user: super_user} do
      scope = Scope.new(actor: super_user)

      assert BelongsTo.input_value(
               region_created_by_field(),
               to_string(super_user.email),
               ctx(scope: scope, state: nil)
             ) == :skip
    end

    test "sends nothing when state is a non-map value", %{super_user: super_user} do
      assert BelongsTo.input_value(
               region_created_by_field(),
               to_string(super_user.email),
               ctx(scope: Scope.new(actor: super_user), state: :something_else)
             ) == :skip
    end

    test "sends nothing for blank/nil values, so nothing is looked up", %{super_user: super_user} do
      scope = Scope.new(actor: super_user)

      for raw <- ["", nil] do
        assert BelongsTo.input_value(
                 region_created_by_field(),
                 raw,
                 ctx(scope: scope, state: %{identity: :email})
               ) == :skip
      end
    end
  end

  describe "input_value/3 — composite identity" do
    test "resolves to the asset's id when the composite lookup hits", %{
      super_user: super_user
    } do
      scope = Scope.new(actor: super_user)
      tag = System.unique_integer([:positive])
      asset = Ash.create!(Asset, %{serial_number: "SN#{tag}", batch_number: "BA#{tag}"})
      composite = %{serial_number: asset.serial_number, batch_number: asset.batch_number}

      assert {:ok, {:lookup, AshBulkDurable.Test.Asset, :serial_and_batch, ^composite}} =
               BelongsTo.input_value(
                 booking_asset_field(),
                 composite,
                 ctx(scope: scope, state: %{identity: :serial_and_batch})
               )

      assert resolve(booking_asset_field(), composite, :serial_and_batch, scope) ==
               {:ok, asset.id}
    end

    test "fails the row listing every sub-key when the composite lookup misses",
         %{super_user: super_user} do
      scope = Scope.new(actor: super_user)
      missing_serial = "NO-SUCH-#{System.unique_integer([:positive])}"

      composite = %{serial_number: missing_serial, batch_number: nil}

      assert {:error, %{field: :asset_id} = error} =
               resolve(booking_asset_field(), composite, :serial_and_batch, scope)

      message = Exception.message(error)
      assert message =~ "no Asset"
      assert message =~ "batch_number = nil"
      assert message =~ "serial_number = #{inspect(missing_serial)}"
    end
  end

  describe "default lifecycle (via use AshBulkDurable.Sheet.FieldHandler)" do
    test "companion_requirement/1 returns nil" do
      assert BelongsTo.companion_requirement(region_created_by_field()) == nil
    end

    test "prepare/2 returns {:ok, nil}" do
      ctx = %PrepareContext{scope: nil, tenant: nil}
      assert BelongsTo.prepare(region_created_by_field(), ctx) == {:ok, nil}
    end

    test "finish/2 returns :ok" do
      assert BelongsTo.finish(region_created_by_field(), nil) == :ok
    end
  end
end
