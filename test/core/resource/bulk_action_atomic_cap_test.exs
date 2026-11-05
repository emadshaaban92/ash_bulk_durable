defmodule AshBulkDurable.Core.Resource.BulkActionAtomicCapTest do
  @moduledoc """
  Atomic-mode row-cap tests for `AshBulkDurable.Core.Resource.BulkAction`
  (`ValidateAtomicModeLimit`). Exercises the framework extension through
  a shell resource (`AshBulkDurable.Test.BulkAction`).

  `async: false` — each test swaps the global `:atomic_mode_max_rows`
  setting via app env.
  """
  use AshBulkDurable.DataCase, async: false

  alias AshBulkDurable.Test.{BulkAction, Row}

  @valid_rows [
    %{input: %{sku: "A", name: "Alpha"}},
    %{input: %{sku: "B", name: "Beta"}}
  ]

  defp create_attrs(overrides) do
    Map.merge(
      %{
        user_id: Ecto.UUID.generate(),
        resource_name: "AshBulkDurable.Test.Asset",
        action_name: :create,
        action_type: :create,
        total_rows: length(@valid_rows),
        mode: :per_row,
        chunk_size: 50,
        rows: @valid_rows
      },
      overrides
    )
  end

  defp create_bulk_action!(overrides) do
    overrides
    |> create_attrs()
    |> then(&Ash.create!(BulkAction, &1, action: :create, authorize?: false))
  end

  describe "atomic-mode cap (ValidateAtomicModeLimit)" do
    test "rejects atomic-mode submits over :atomic_mode_max_rows before inserting rows" do
      AshBulkDurable.StorageHelpers.put_config(:atomic_mode_max_rows, 1)

      rows_before = AshBulkDurable.Test.Repo.aggregate(Row, :count, :id)
      bulk_actions_before = AshBulkDurable.Test.Repo.aggregate(BulkAction, :count, :id)

      attrs = create_attrs(%{mode: :all_or_nothing})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(BulkAction, attrs, action: :create, authorize?: false)

      assert AshBulkDurable.Test.Repo.aggregate(Row, :count, :id) == rows_before
      assert AshBulkDurable.Test.Repo.aggregate(BulkAction, :count, :id) == bulk_actions_before
    end

    test "allows atomic-mode submits at or below the cap" do
      AshBulkDurable.StorageHelpers.put_config(:atomic_mode_max_rows, 2)

      assert %BulkAction{} = create_bulk_action!(%{mode: :all_or_nothing})
    end

    test "never caps a per-row bulk action" do
      AshBulkDurable.StorageHelpers.put_config(:atomic_mode_max_rows, 1)

      assert %BulkAction{} =
               create_bulk_action!(%{mode: :per_row, chunk_size: length(@valid_rows)})
    end
  end
end
