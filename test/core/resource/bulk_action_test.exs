defmodule AshBulkDurable.Core.Resource.BulkActionTest do
  @moduledoc """
  Action smoke + uniqueness + rollback + PubSub tests for
  `AshBulkDurable.Core.Resource.BulkAction`. Exercises the framework extension
  through a shell resource (`AshBulkDurable.Test.BulkAction`).
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Test.{BulkAction, Row}

  @valid_rows [
    %{input: %{sku: "A", name: "Alpha"}, metadata: %{"SKU" => "A"}},
    %{input: %{sku: "B", name: "Beta"}, metadata: %{"SKU" => "B"}}
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

  defp create_bulk_action!(overrides \\ %{}) do
    overrides
    |> create_attrs()
    |> then(&Ash.create!(BulkAction, &1, action: :create, authorize?: false))
  end

  describe ":create" do
    test "persists the bulk action, :queued, and its rows — all atomically" do
      bulk_action = create_bulk_action!()

      assert bulk_action.status == :queued
      assert bulk_action.total_rows == 2
      assert bulk_action.attempts == 0
      assert bulk_action.claim_token == nil

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).rows_done == 0

      rows =
        Row
        |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 2
      # Holding no reference, each row is born resolved.
      assert Enum.all?(rows, &(&1.status == :resolved))
      assert Enum.map(rows, & &1.row_index) |> Enum.sort() == [0, 1]

      assert rows |> Enum.sort_by(& &1.row_index) |> Enum.map(&Map.take(&1, [:input, :metadata])) ==
               @valid_rows
    end
  end

  describe "partial unique index" do
    test "second create for same user while queued/running raises Ash.Error.Invalid" do
      user_id = Ecto.UUID.generate()
      # The first bulk action holds the per-user slot; the second create must then fail.
      _first = create_bulk_action!(%{user_id: user_id})

      rows_before = AshBulkDurable.Test.Repo.aggregate(Row, :count, :id)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(BulkAction, create_attrs(%{user_id: user_id}),
                 action: :create,
                 authorize?: false
               )

      # The full create transaction (bulk action + rows) rolled back because
      # the unique violation raised inside the same Ash.create.
      assert AshBulkDurable.Test.Repo.aggregate(Row, :count, :id) == rows_before
    end

    test "creating after the previous bulk action reached a terminal state succeeds" do
      user_id = Ecto.UUID.generate()
      first = create_bulk_action!(%{user_id: user_id})

      finished =
        Ash.update!(first, %{result: :completed},
          action: :mark_finished,
          authorize?: false
        )

      assert finished.status == :completed

      assert %BulkAction{} = create_bulk_action!(%{user_id: user_id})
    end

    test "a :completed_with_errors bulk action still holds the slot — second create is rejected" do
      user_id = Ecto.UUID.generate()
      first = create_bulk_action!(%{user_id: user_id})

      parked =
        Ash.update!(first, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      assert parked.status == :completed_with_errors

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(BulkAction, create_attrs(%{user_id: user_id}),
                 action: :create,
                 authorize?: false
               )
    end

    test "abandoning a :completed_with_errors bulk action releases the slot" do
      user_id = Ecto.UUID.generate()
      first = create_bulk_action!(%{user_id: user_id})

      parked =
        Ash.update!(first, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      cancelled =
        Ash.update!(parked, %{result: :cancelled}, action: :mark_finished, authorize?: false)

      assert cancelled.status == :cancelled

      assert %BulkAction{} = create_bulk_action!(%{user_id: user_id})
    end

    test "retrying a :completed_with_errors bulk action queues it again without a violation" do
      user_id = Ecto.UUID.generate()
      first = create_bulk_action!(%{user_id: user_id})

      parked =
        Ash.update!(first, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      # The bulk action already holds the one-unresolved slot; the
      # completed_with_errors → queued flip stays inside the index
      # predicate, so it can never collide with itself.
      retried = Ash.update!(parked, %{}, action: :enqueue_retry, authorize?: false)
      assert retried.status == :queued
    end
  end

  describe "row counts" do
    test "rows_done counts the succeeded rows, rows_pending the pending ones" do
      bulk_action = create_bulk_action!()
      assert %{rows_done: 0, rows_pending: 0} = reread(bulk_action)

      [row | _rest] =
        Row
        |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
        |> Ash.read!(authorize?: false)

      Ash.update!(row, %{record_id: "1"}, action: :mark_succeeded, authorize?: false)
      assert %{rows_done: 1} = reread(bulk_action)
    end

    defp reread(bulk_action),
      do:
        Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending])
  end

  describe ":mark_finished" do
    test "stamps finished_at and flips status to :completed" do
      bulk_action = create_bulk_action!()
      assert is_nil(bulk_action.finished_at)

      done =
        Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)

      assert done.status == :completed
      assert %DateTime{} = done.finished_at
    end

    test "supports :completed_with_errors, {:failed, term}, and :cancelled outcomes" do
      bulk_action_a = create_bulk_action!()
      bulk_action_b = create_bulk_action!(%{user_id: Ecto.UUID.generate()})
      bulk_action_c = create_bulk_action!(%{user_id: Ecto.UUID.generate()})

      a =
        Ash.update!(bulk_action_a, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      b =
        Ash.update!(bulk_action_b, %{result: {:failed, :boom}},
          action: :mark_finished,
          authorize?: false
        )

      c =
        Ash.update!(bulk_action_c, %{result: :cancelled},
          action: :mark_finished,
          authorize?: false
        )

      assert a.status == :completed_with_errors
      assert b.status == :failed
      assert c.status == :cancelled
    end

    test "rejects a second finalize on an already-terminal bulk action (worker-vs-rescue race)" do
      bulk_action = create_bulk_action!()

      done =
        Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)

      assert done.status == :completed

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.update(done, %{result: {:failed, :worker_lost}},
                 action: :mark_finished,
                 authorize?: false
               )

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      # Original verdict survives the race.
      reread =
        Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending])

      assert reread.status == :completed
    end
  end

  describe ":enqueue_retry" do
    test "is rejected while the bulk action is queued or running (double-retry race)" do
      bulk_action = create_bulk_action!()
      assert bulk_action.status == :queued

      {:ok, running} = AshBulkDurable.Core.Lease.claim_one(bulk_action.id)
      assert running.status == :running

      for held <- [bulk_action, running] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 Ash.update(held, %{}, action: :enqueue_retry, authorize?: false)

        assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      end

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).status == :running
    end

    test "takes a bulk action that finished with failed rows, or failed outright" do
      for result <- [:completed_with_errors, {:failed, :worker_lost}] do
        finished =
          %{user_id: Ecto.UUID.generate()}
          |> create_bulk_action!()
          |> Ash.update!(%{result: result}, action: :mark_finished, authorize?: false)

        assert Ash.update!(finished, %{}, action: :enqueue_retry, authorize?: false).status ==
                 :queued
      end
    end
  end

  describe ":fetch_for_user_unresolved" do
    test "returns the unresolved bulk action for a user, nil otherwise" do
      user_id = Ecto.UUID.generate()
      assert {:error, %Ash.Error.Query.NotFound{}} = read_unresolved(user_id)

      bulk_action = create_bulk_action!(%{user_id: user_id})
      assert {:ok, found} = read_unresolved(user_id)
      assert found.id == bulk_action.id

      Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)
      assert {:error, %Ash.Error.Query.NotFound{}} = read_unresolved(user_id)
    end

    test "a parked :completed_with_errors bulk action is still returned" do
      user_id = Ecto.UUID.generate()
      bulk_action = create_bulk_action!(%{user_id: user_id})

      parked =
        Ash.update!(bulk_action, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      assert {:ok, found} = read_unresolved(user_id)
      assert found.id == parked.id
      assert found.status == :completed_with_errors

      Ash.update!(parked, %{result: :cancelled}, action: :mark_finished, authorize?: false)
      assert {:error, %Ash.Error.Query.NotFound{}} = read_unresolved(user_id)
    end

    defp read_unresolved(user_id) do
      BulkAction
      |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user_id})
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} -> {:error, %Ash.Error.Query.NotFound{}}
        {:ok, bulk_action} -> {:ok, bulk_action}
        other -> other
      end
    end
  end

  describe "PubSub" do
    test "broadcasts on `bulk_action:<id>` for every update" do
      bulk_action = create_bulk_action!()
      topic = "bulk_action:#{bulk_action.id}"
      :ok = AshBulkDurable.Test.PubSub.subscribe(topic)

      Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)

      assert_receive {^topic, _event, %Ash.Notifier.Notification{data: %BulkAction{id: id}}}, 500

      assert id == bulk_action.id
    end
  end

  describe "Row cascade delete" do
    test "deleting an BulkAction cascades to its Rows" do
      bulk_action = create_bulk_action!()

      rows_before =
        Row
        |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
        |> Ash.read!(authorize?: false)

      assert length(rows_before) == 2

      Ash.destroy!(bulk_action, authorize?: false)

      rows_after =
        Row
        |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
        |> Ash.read!(authorize?: false)

      assert rows_after == []
    end
  end
end
