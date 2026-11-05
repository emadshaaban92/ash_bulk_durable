defmodule AshBulkDurable.SheetTest do
  @moduledoc """
  Tests for `AshBulkDurable.Sheet`'s field-handler resolver.

  Runs synchronously because every test mutates the global `:ash_bulk_durable`
  config and restores it via `on_exit/2`.
  """
  use ExUnit.Case, async: false

  alias AshBulkDurable.Sheet.Field
  alias AshBulkDurable.Sheet.FieldHandlers.BelongsTo
  alias AshBulkDurable.Sheet.FieldHandlers.Scalar
  alias AshBulkDurable.Test.Region

  # ---- Test-only handler modules ------------------------------------------

  defmodule AlwaysWinsScalar do
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%Field{}), do: true

    @impl true
    def input_value(_field, value, _ctx), do: {:ok, value}
  end

  defmodule RegionNameUpdateOnly do
    @moduledoc """
    Pattern-matched handler that only claims `:name` on `Region.update` — the
    canary for the per-resource/per-action override use case.
    """
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%Field{
          resource: AshBulkDurable.Test.Region,
          action: %{name: :update},
          field: %{name: :name}
        }),
        do: true

    def handles?(_), do: false

    @impl true
    def input_value(_field, value, _ctx), do: {:ok, value}
  end

  # ---- Helpers ------------------------------------------------------------

  defp wrap(ash_field, action_name) do
    %Field{
      field: ash_field,
      resource: Region,
      action: Ash.Resource.Info.action(Region, action_name)
    }
  end

  defp set_config(opts) do
    AshBulkDurable.StorageHelpers.put_config(:field_handlers, opts[:field_handlers] || [])
    AshBulkDurable.StorageHelpers.put_config(:disable_defaults, opts[:disable_defaults] || [])
  end

  # ---- Tests --------------------------------------------------------------

  describe "default_handlers/0" do
    test "ships Scalar and BelongsTo by default" do
      assert AshBulkDurable.Sheet.default_handlers() == [Scalar, BelongsTo]
    end
  end

  describe "handlers/0 (resolution)" do
    test "returns just the defaults with no app config" do
      set_config([])
      assert AshBulkDurable.Sheet.handlers() == [Scalar, BelongsTo]
    end

    test "prepends `:field_handlers` to the defaults" do
      set_config(field_handlers: [AlwaysWinsScalar])
      assert AshBulkDurable.Sheet.handlers() == [AlwaysWinsScalar, Scalar, BelongsTo]
    end

    test "subtracts `:disable_defaults`" do
      set_config(disable_defaults: [Scalar])
      assert AshBulkDurable.Sheet.handlers() == [BelongsTo]
    end

    test "combines prepend + disable" do
      set_config(field_handlers: [AlwaysWinsScalar], disable_defaults: [Scalar])
      assert AshBulkDurable.Sheet.handlers() == [AlwaysWinsScalar, BelongsTo]
    end
  end

  describe "handler_for/1 (first-handles?-wins)" do
    test "returns Scalar for a plain attribute with no app overrides" do
      set_config([])
      bf = wrap(Ash.Resource.Info.attribute(Region, :name), :create)
      assert AshBulkDurable.Sheet.handler_for(bf) == Scalar
    end

    test "returns BelongsTo for a belongs_to relationship" do
      set_config([])
      bf = wrap(Ash.Resource.Info.relationship(Region, :inserted_by), :create)
      assert AshBulkDurable.Sheet.handler_for(bf) == BelongsTo
    end

    test "returns nil when no handler claims the field" do
      set_config([])

      # Embedded resources aren't claimed by Scalar or BelongsTo.
      attr = %Ash.Resource.Attribute{name: :cover, type: AshBulkDurable.Test.PhotoEmbed}

      bf = %Field{field: attr, resource: AshBulkDurable.Test.Asset, action: nil}
      assert AshBulkDurable.Sheet.handler_for(bf) == nil
    end

    test "an app handler that claims everything shadows the default Scalar" do
      set_config(field_handlers: [AlwaysWinsScalar])
      bf = wrap(Ash.Resource.Info.attribute(Region, :name), :create)
      assert AshBulkDurable.Sheet.handler_for(bf) == AlwaysWinsScalar
    end

    test "per-resource + per-action override claims only the specific tuple" do
      set_config(field_handlers: [RegionNameUpdateOnly])

      name_attr = Ash.Resource.Info.attribute(Region, :name)
      code_attr = Ash.Resource.Info.attribute(Region, :code)

      # Hits the exact (resource, action, field) pattern → custom wins.
      assert AshBulkDurable.Sheet.handler_for(wrap(name_attr, :update)) ==
               RegionNameUpdateOnly

      # Different action → custom doesn't claim, default Scalar takes over.
      assert AshBulkDurable.Sheet.handler_for(wrap(name_attr, :create)) == Scalar

      # Different field on the same action → custom doesn't claim either.
      assert AshBulkDurable.Sheet.handler_for(wrap(code_attr, :update)) == Scalar
    end
  end
end
