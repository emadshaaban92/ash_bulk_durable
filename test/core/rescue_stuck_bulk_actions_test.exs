defmodule AshBulkDurable.Core.RescueStuckBulkActionsTest do
  @moduledoc """
  Tests for the stuck bulk action rescue cron. Each bulk action is created with a
  real Oban job (via the `:create` after-action); the test then forces
  that job into a terminal/healthy state — or deletes it — and asserts
  the cron only flips the provably-dead ones.
  """
  use AshBulkDurable.DataCase, async: true
  use Oban.Testing, repo: AshBulkDurable.Test.Repo

  import Ecto.Query

  alias AshBulkDurable.Core.RescueStuckBulkActions
  alias AshBulkDurable.Test.BulkAction

  defp create_bulk_action! do
    Ash.create!(
      BulkAction,
      %{
        user_id: Ecto.UUID.generate(),
        resource_name: "AshBulkDurable.Test.Region",
        action_name: :create,
        action_type: :create,
        total_rows: 1,
        mode: :per_row,
        chunk_size: 50,
        rows: [%{input: %{name: "X"}}]
      },
      action: :create,
      authorize?: false
    )
  end

  defp set_job_state(bulk_action, state) do
    from(j in Oban.Job, where: j.id == ^bulk_action.oban_job_id)
    |> AshBulkDurable.Test.Repo.update_all(set: [state: state, attempted_at: DateTime.utc_now()])
  end

  defp delete_job(bulk_action) do
    from(j in Oban.Job, where: j.id == ^bulk_action.oban_job_id)
    |> AshBulkDurable.Test.Repo.delete_all()
  end

  defp reload(%BulkAction{id: id}), do: Ash.get!(BulkAction, id, authorize?: false)

  describe "perform/1 sweep" do
    test "flips a bulk action whose job is :discarded to :failed/worker_lost" do
      bulk_action = create_bulk_action!()
      set_job_state(bulk_action, "discarded")

      assert :ok = perform_job(RescueStuckBulkActions, %{})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.result["reason"] == "worker_lost"
      assert %DateTime{} = fresh.finished_at
    end

    test "rescues everyone past a bulk action whose action is gone" do
      gone = create_bulk_action!()
      stuck = create_bulk_action!()
      delete_job(gone)
      delete_job(stuck)

      AshBulkDurable.Test.Repo.query!("UPDATE bulk_actions SET action_name = $1 WHERE id = $2", [
        "gone_#{System.unique_integer([:positive])}",
        Ecto.UUID.dump!(gone.id)
      ])

      assert :ok = perform_job(RescueStuckBulkActions, %{})

      assert reload(gone).status == :failed
      assert reload(stuck).status == :failed
    end

    test "flips a bulk action whose job row was pruned to :failed/worker_lost" do
      bulk_action = create_bulk_action!()
      delete_job(bulk_action)

      assert :ok = perform_job(RescueStuckBulkActions, %{})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.result["reason"] == "worker_lost"
    end

    test "leaves a bulk action whose job is :executing untouched" do
      bulk_action = create_bulk_action!()
      set_job_state(bulk_action, "executing")

      assert :ok = perform_job(RescueStuckBulkActions, %{})

      fresh = reload(bulk_action)
      assert fresh.status == :queued
      assert is_nil(fresh.finished_at)
    end

    test "leaves a bulk action whose job is :available (queued, unpicked) untouched" do
      bulk_action = create_bulk_action!()
      # Freshly enqueued jobs are already :available, but assert explicitly.
      set_job_state(bulk_action, "available")

      assert :ok = perform_job(RescueStuckBulkActions, %{})

      assert reload(bulk_action).status == :queued
    end
  end

  describe "rescue_if_stuck/1 status guard" do
    test "a parked :completed_with_errors bulk action is never treated as stuck" do
      bulk_action = create_bulk_action!()
      # The worker finished legitimately: its job is terminal AND the bulk action is
      # parked in :completed_with_errors holding the one-unresolved slot.
      # Without the status guard, the mount-time rescue would see the
      # terminal job and flip this healthy run to :failed.
      set_job_state(bulk_action, "completed")

      parked =
        Ash.update!(bulk_action, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      assert %BulkAction{status: :completed_with_errors} =
               RescueStuckBulkActions.rescue_if_stuck(parked)

      assert reload(bulk_action).status == :completed_with_errors
    end

    test "a :queued bulk action with a dead job is still rescued" do
      bulk_action = create_bulk_action!()
      set_job_state(bulk_action, "discarded")

      assert %BulkAction{status: :failed} =
               RescueStuckBulkActions.rescue_if_stuck(reload(bulk_action))
    end
  end

  describe "mark_worker_lost/1 TOCTOU guard" do
    test "leaves the bulk action untouched if a healthy worker advanced status in the window" do
      bulk_action = create_bulk_action!()
      set_job_state(bulk_action, "discarded")

      # Simulate the race: between worker_lost?/1 reading the Oban job and
      # mark_worker_lost/1 writing :failed, a real worker (or the user's
      # Abandon path) moved the bulk action past :queued/:running. The in-memory
      # struct still says :queued, mirroring what rescue_if_stuck/1 just
      # checked at its entry.
      _advanced =
        Ash.update!(bulk_action, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      result = RescueStuckBulkActions.mark_worker_lost(bulk_action)

      # The call returns the original (stale) run untouched and the DB row
      # keeps the status the healthy worker wrote — no clobber.
      assert result.id == bulk_action.id
      assert result.status == :queued
      assert reload(bulk_action).status == :completed_with_errors
      refute reload(bulk_action).result["reason"] == "worker_lost"
    end
  end

  describe "worker_lost?/1" do
    test "true for nil oban_job_id, true for terminal states, false for live states" do
      assert RescueStuckBulkActions.worker_lost?(%{oban_job_id: nil})

      bulk_action = create_bulk_action!()

      set_job_state(bulk_action, "completed")
      assert RescueStuckBulkActions.worker_lost?(reload(bulk_action))

      set_job_state(bulk_action, "executing")
      refute RescueStuckBulkActions.worker_lost?(reload(bulk_action))
    end
  end
end
