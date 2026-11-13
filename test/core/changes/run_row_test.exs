defmodule AshBulkDurable.Core.Changes.RunRowTest do
  @moduledoc """
  Spike proof for the `:run` action on `Row` (create path). Verifies that
  driving the row through `Ash.bulk_update(rows, :run)` creates the target
  records and flips each row's status in the same transaction — and that a
  single row works as a batch of 1.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Test.{BulkAction, PubSub, Row}
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
    {:ok, scope} =
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

  # The `rows_done` bump is a nested `Ash.update!/2` in the change's
  # `after_batch/3`, inside the chunk's transaction. A page must hear of it
  # only once that transaction commits, and never of one rolled back. Ash
  # gives it neither to the batch's result nor to the page at once: it
  # queues it, and the outermost `Ash.transaction/3` sends it after the
  # commit, or drops it on a rollback.
  describe "a nested update's notification inside the batch" do
    setup %{super_user: user} do
      n = System.unique_integer([:positive])
      inputs = [%{name: "Note-#{n}", native_name: "AR Note-#{n}", code: "N-#{n}"}]
      bulk_action = create_bulk_action!(inputs, user)
      topic = "bulk_action:#{bulk_action.id}"
      :ok = PubSub.subscribe(topic)
      %{bulk_action: bulk_action, topic: topic}
    end

    defp run_in_transaction(bulk_action, then) do
      Ash.transaction([BulkAction, Row], fn ->
        result =
          Ash.bulk_update(rows(bulk_action.id), :run, %{},
            strategy: :stream,
            transaction: :all,
            return_records?: true,
            return_errors?: true,
            return_notifications?: true,
            authorize?: false,
            context: context_for(bulk_action)
          )

        then.(result)
      end)
    end

    test "is sent once the transaction commits, not before", %{
      bulk_action: bulk_action,
      topic: topic
    } do
      {:ok, result} =
        run_in_transaction(bulk_action, fn result ->
          refute_received {^topic, _event, _payload}
          result
        end)

      assert result.status == :success
      refute Enum.any?(result.notifications, &(&1.action.name == :bump_rows_done))

      assert_received {^topic, "bump_rows_done",
                       %Ash.Notifier.Notification{data: %BulkAction{rows_done: 1}}}

      refute_received {^topic, _event, _payload}
    end

    test "is never sent when the transaction rolls back", %{
      bulk_action: bulk_action,
      topic: topic
    } do
      assert {:error, _rolled_back} =
               run_in_transaction(bulk_action, fn %{status: :success} ->
                 Ash.DataLayer.rollback(BulkAction, :rolled_back)
               end)

      refute_received {^topic, _event, _payload}
    end
  end
end
