defmodule AshBulkDurable.Sheet.FieldHandlers.ScalarTest do
  use ExUnit.Case, async: true

  alias AshBulkDurable.Sheet.Field
  alias AshBulkDurable.Sheet.FieldHandlers.Scalar
  alias AshBulkDurable.Sheet.RowContext
  alias AshBulkDurable.Test.Region

  defp wrap(ash_field, action_name \\ :create) do
    %Field{
      field: ash_field,
      resource: Region,
      action: Ash.Resource.Info.action(Region, action_name)
    }
  end

  defp empty_ctx, do: %RowContext{row_index: 0, row: %{}, state: nil}

  describe "handles?/1" do
    test "claims plain attributes" do
      assert Scalar.handles?(wrap(Ash.Resource.Info.attribute(Region, :name)))
      assert Scalar.handles?(wrap(Ash.Resource.Info.attribute(Region, :code)))
    end

    test "claims action arguments" do
      arg = %Ash.Resource.Actions.Argument{name: :search, type: :string}
      assert Scalar.handles?(wrap(arg))
    end

    test "rejects belongs_to relationships" do
      rel = Ash.Resource.Info.relationship(Region, :inserted_by)
      refute Scalar.handles?(wrap(rel))
    end

    test "rejects a raw atom (defensive: field never fully resolved)" do
      refute Scalar.handles?(%Field{field: :unresolved, resource: Region, action: nil})
    end

    test "claims short-name primitives like :string" do
      arg = %Ash.Resource.Actions.Argument{name: :foo, type: :string}
      assert Scalar.handles?(wrap(arg))
    end

    test "claims module-name primitives like Ash.Type.String" do
      arg = %Ash.Resource.Actions.Argument{name: :foo, type: Ash.Type.String}
      assert Scalar.handles?(wrap(arg))
    end

    test "claims arrays of primitives" do
      arg = %Ash.Resource.Actions.Argument{name: :tags, type: {:array, :string}}
      assert Scalar.handles?(wrap(arg))
    end

    test "unwraps Ash.Type.NewType chains (Note wraps :string)" do
      arg = %Ash.Resource.Actions.Argument{name: :note, type: AshBulkDurable.Test.Note}
      assert Scalar.handles?(wrap(arg))
    end

    test "rejects embedded resources" do
      attr = %Ash.Resource.Attribute{name: :cover, type: AshBulkDurable.Test.PhotoEmbed}
      refute Scalar.handles?(wrap(attr))
    end

    test "rejects custom Ash.Type modules outside the primitive list (e.g. a blob)" do
      arg = %Ash.Resource.Actions.Argument{name: :file, type: AshBulkDurable.Test.Blob}
      refute Scalar.handles?(wrap(arg))
    end

    test "rejects {:array, <embedded resource>}" do
      arg = %Ash.Resource.Actions.Argument{
        name: :images,
        type: {:array, AshBulkDurable.Test.PhotoEmbed}
      }

      refute Scalar.handles?(wrap(arg))
    end

    test "rejects unmappable builtin types like :map and :tuple" do
      refute Scalar.handles?(wrap(%Ash.Resource.Actions.Argument{name: :data, type: :map}))
      refute Scalar.handles?(wrap(%Ash.Resource.Actions.Argument{name: :data, type: :tuple}))
    end
  end

  # The value goes to the action under the field's name, attribute or
  # argument alike, as a form's params do.
  describe "input_value/3" do
    test "gives an attribute's cell as its value" do
      bf = wrap(Ash.Resource.Info.attribute(Region, :name))

      assert Scalar.input_value(bf, "Acme", empty_ctx()) == {:ok, "Acme"}
    end

    test "gives an argument's cell as its value" do
      arg = %Ash.Resource.Actions.Argument{name: :foo, type: :string}

      assert Scalar.input_value(wrap(arg), "bar", empty_ctx()) == {:ok, "bar"}
    end

    test "splits pipe-delimited cells for {:array, _} types" do
      arg = %Ash.Resource.Actions.Argument{name: :tags, type: {:array, :string}}

      assert Scalar.input_value(wrap(arg), "alpha|beta|gamma", empty_ctx()) ==
               {:ok, ["alpha", "beta", "gamma"]}
    end

    test "trims whitespace and drops empty entries when splitting arrays" do
      arg = %Ash.Resource.Actions.Argument{name: :tags, type: {:array, :string}}

      assert Scalar.input_value(wrap(arg), "  a |  | b ", empty_ctx()) == {:ok, ["a", "b"]}
    end

    test "leaves non-array values untouched" do
      arg = %Ash.Resource.Actions.Argument{name: :foo, type: :string}

      assert Scalar.input_value(wrap(arg), "a|b", empty_ctx()) == {:ok, "a|b"}
    end
  end

  describe "default lifecycle (via use AshBulkDurable.Sheet.FieldHandler)" do
    test "companion_requirement/1 returns nil" do
      bf = wrap(Ash.Resource.Info.attribute(Region, :name))
      assert Scalar.companion_requirement(bf) == nil
    end

    test "prepare/2 returns {:ok, nil}" do
      bf = wrap(Ash.Resource.Info.attribute(Region, :name))
      ctx = %AshBulkDurable.Sheet.PrepareContext{scope: nil, tenant: nil}
      assert Scalar.prepare(bf, ctx) == {:ok, nil}
    end

    test "finish/2 returns :ok" do
      bf = wrap(Ash.Resource.Info.attribute(Region, :name))
      assert Scalar.finish(bf, nil) == :ok
    end
  end
end
