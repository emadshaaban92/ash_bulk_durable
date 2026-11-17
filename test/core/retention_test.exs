defmodule AshBulkDurable.Core.RetentionTest do
  @moduledoc """
  The retention prune (`Retention.prune/1`), which each node's poller runs
  before the staged-file sweep. Bulk actions skipped because another
  transaction holds them are tested in `BulkActionLockTest`, which has a
  second real connection.

  `async: false`: one test sets the `:retention` config.
  """
  use AshBulkDurable.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshBulkDurable.Core.Retention
  alias AshBulkDurable.Test.{BulkAction, Row}

  @day :timer.hours(24)

  defp create_bulk_action! do
    Ash.create!(
      BulkAction,
      %{
        user_id: Ecto.UUID.generate(),
        resource_name: "AshBulkDurable.Test.Region",
        action_name: :create,
        action_type: :create,
        total_rows: 2,
        mode: :per_row,
        chunk_size: 50,
        rows: [%{input: %{name: "X"}}, %{input: %{name: "Y"}}]
      },
      action: :create,
      authorize?: false
    )
  end

  # A bulk action finished with `result`, `ago` milliseconds ago.
  defp finished!(result, ago) do
    bulk_action =
      Ash.update!(create_bulk_action!(), %{result: result},
        action: :mark_finished,
        authorize?: false
      )

    Repo.query!(
      "UPDATE bulk_actions SET finished_at = (now() AT TIME ZONE 'utc') - " <>
        "($1 * interval '1 millisecond') WHERE id = $2",
      [ago, Ecto.UUID.dump!(bulk_action.id)]
    )

    bulk_action
  end

  defp kept?(bulk_action),
    do: match?({:ok, _}, Ash.get(BulkAction, bulk_action.id, authorize?: false))

  defp row_count(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.count!(authorize?: false)
  end

  test "deletes nothing with no retention, however old" do
    completed = finished!(:completed, 400 * @day)

    assert Retention.prune(nil) == 0
    assert kept?(completed)
  end

  test "reads the :retention config by default" do
    completed = finished!(:completed, 2 * @day)

    AshBulkDurable.StorageHelpers.put_config(:retention, @day)

    assert Retention.prune() == 1
    refute kept?(completed)
  end

  test "deletes completed, failed and cancelled bulk actions past retention, with their rows" do
    old =
      for result <- [:completed, {:failed, %{reason: :worker_lost}}, :cancelled],
          do: finished!(result, 2 * @day)

    assert Enum.all?(old, &(row_count(&1) == 2))

    assert Retention.prune(@day) == 3

    for bulk_action <- old do
      refute kept?(bulk_action)
      assert row_count(bulk_action) == 0
    end
  end

  test "keeps those that finished within retention" do
    recent = finished!(:completed, @day - :timer.minutes(5))

    assert Retention.prune(@day) == 0
    assert kept?(recent)
    assert row_count(recent) == 2
  end

  test "keeps unresolved bulk actions, however old" do
    with_errors = finished!(:completed_with_errors, 400 * @day)

    # Queued or running with a `finished_at`, as a retry may leave it.
    [queued, running] =
      for status <- ["queued", "running"] do
        bulk_action = create_bulk_action!()

        Repo.query!(
          "UPDATE bulk_actions SET status = $1, finished_at = now() - interval '400 days' " <>
            "WHERE id = $2",
          [status, Ecto.UUID.dump!(bulk_action.id)]
        )

        bulk_action
      end

    assert Retention.prune(@day) == 0
    assert kept?(with_errors) and kept?(queued) and kept?(running)
  end

  test "keeps one whose delete fails, logs it, and deletes the others" do
    [pinned | others] = for _ <- 1..4, do: finished!(:completed, 2 * @day)

    # A host table that references a bulk action without cascading, gone with
    # the sandbox's transaction.
    Repo.query!(
      "CREATE TABLE retention_test_pins (bulk_action_id uuid REFERENCES bulk_actions (id))"
    )

    Repo.query!("INSERT INTO retention_test_pins VALUES ($1)", [Ecto.UUID.dump!(pinned.id)])

    log = capture_log(fn -> assert Retention.prune(@day) == 3 end)

    assert log =~ "could not delete bulk action #{pinned.id}"
    assert kept?(pinned) and row_count(pinned) == 2
    refute Enum.any?(others, &kept?/1)
  end

  # `finished_at` holds UTC without a zone; the database's own clock is
  # compared in UTC whatever the session's time zone.
  test "reads finished_at as UTC, whatever the session's time zone" do
    for {zone, kept_ago, deleted_ago} <- [
          {"Pacific/Auckland", @day - :timer.hours(1), @day + :timer.hours(1)},
          {"America/Los_Angeles", @day - :timer.hours(1), @day + :timer.hours(1)}
        ] do
      kept = finished!(:completed, kept_ago)
      deleted = finished!(:completed, deleted_ago)

      Repo.query!("SET LOCAL TIME ZONE '#{zone}'")
      assert Retention.prune(@day) == 1
      Repo.query!("SET LOCAL TIME ZONE 'UTC'")

      assert kept?(kept), "#{zone}: kept the one #{kept_ago} ms old"
      refute kept?(deleted), "#{zone}: deleted the one #{deleted_ago} ms old"
    end
  end

  test "refuses a retention that isn't nil or a positive integer" do
    for bad <- [0, -1, 1.5, "1 day", :forever] do
      assert_raise ArgumentError, ~r/:retention must be nil or a positive number/, fn ->
        Retention.prune(bad)
      end
    end
  end
end
