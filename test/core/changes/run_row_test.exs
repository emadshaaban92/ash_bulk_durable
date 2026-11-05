defmodule AshBulkDurable.Core.Changes.RunRowTest do
  @moduledoc """
  Spike proof for the `:run` action on `Row` (create path). Verifies that
  driving the row through `Ash.bulk_update(rows, :run)` creates the target
  records and flips each row's status in the same transaction — and that a
  single row works as a batch of 1.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Test.{BulkAction, Row}
  alias AshBulkDurable.Test.Region

  defp create_bulk_action!(inputs, user) do
    Ash.create!(
      BulkAction,
      %{
        user_id: user.id,
        resource_name: "AshBulkDurable.Test.Region",
        action_name: :create,
        action_type: :create,
        total_rows: length(inputs),
        mode: :per_row,
        chunk_size: 50,
        rows: Enum.map(inputs, &%{input: &1})
      },
      action: :create,
      authorize?: false
    )
  end

  defp rows(bulk_action_id) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp run_bulk(rows, bulk_action) do
    Ash.bulk_update(rows, :run, %{},
      strategy: :stream,
      transaction: :all,
      return_records?: true,
      return_errors?: true,
      notify?: false,
      authorize?: false,
      context: context_for(bulk_action)
    )
  end

  # Mirrors how the worker builds the bulk action's settings and hands them
  # to the :run action via context.
  defp context_for(bulk_action) do
    scope =
      AshBulkDurable.Core.Owner.scope_from_worker_key(bulk_action.user_id, bulk_action.tenant)

    settings = AshBulkDurable.Core.Runner.settings(bulk_action, scope, %{})
    %{ash_bulk_durable: %{settings: settings, bulk_action: bulk_action}}
  end

  test "bulk_update(:run) creates the targets and marks every row :succeeded", %{
    super_user: user
  } do
    n = System.unique_integer([:positive])

    inputs =
      Enum.map(
        1..3,
        &%{name: "Run #{&1}-#{n}", native_name: "AR #{&1}-#{n}", code: "R#{&1}-#{n}"}
      )

    bulk_action = create_bulk_action!(inputs, user)
    resolved = rows(bulk_action.id)

    result = run_bulk(resolved, bulk_action)
    assert result.status == :success

    after_rows = rows(bulk_action.id)
    assert Enum.all?(after_rows, &(&1.status == :succeeded))
    assert Enum.all?(after_rows, &is_binary(&1.record_id))

    codes = Enum.map(1..3, &"R#{&1}-#{n}")
    regions = Region |> Ash.Query.filter(code in ^codes) |> Ash.read!(actor: user)
    assert length(regions) == 3
  end

  test "a single row works as a batch of 1", %{super_user: user} do
    n = System.unique_integer([:positive])
    inputs = [%{name: "Solo-#{n}", native_name: "AR Solo-#{n}", code: "S-#{n}"}]

    bulk_action = create_bulk_action!(inputs, user)
    [resolved] = rows(bulk_action.id)

    result = run_bulk([resolved], bulk_action)
    assert result.status == :success

    [after_row] = rows(bulk_action.id)
    assert after_row.status == :succeeded
    assert is_binary(after_row.record_id)

    assert [%Region{}] =
             Region |> Ash.Query.filter(code == ^"S-#{n}") |> Ash.read!(actor: user)
  end
end
