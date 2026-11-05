defmodule AshBulkDurable.Core.RescueStuckBulkActionsPrefixTest do
  @moduledoc """
  The rescue cron on a host whose Oban instance keeps its jobs under a schema
  prefix. The job row lives in `<prefix>.oban_jobs`, so a lookup that ignores
  the prefix reads `public.oban_jobs`, finds nothing, and condemns every live
  bulk action as lost.

  Not async: it points the engine's `:oban` at a second, prefixed instance,
  and the app env is global.
  """
  use AshBulkDurable.DataCase, async: false

  alias AshBulkDurable.Core.{Heartbeat, RescueStuckBulkActions}
  alias AshBulkDurable.Test.{BulkAction, Repo}

  @prefix "rescue_prefixed"
  @oban __MODULE__.Oban

  # Oban checks its migrated version outside the sandbox when an instance
  # starts, so the prefixed table must be committed, not made in a test's
  # transaction. Its rows still roll back with each test.
  setup_all do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
      Repo.query!("CREATE SCHEMA #{@prefix}")
      Repo.query!("CREATE TABLE #{@prefix}.oban_jobs (LIKE public.oban_jobs INCLUDING ALL)")

      # Oban reads that version from the table's comment, which LIKE leaves
      # behind.
      %{rows: [[version]]} =
        Repo.query!("SELECT obj_description('public.oban_jobs'::regclass)")

      Repo.query!("COMMENT ON TABLE #{@prefix}.oban_jobs IS '#{version}'")
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
      end)
    end)
  end

  setup do
    start_supervised!({Oban, name: @oban, repo: Repo, prefix: @prefix, testing: :manual})

    previous = Application.fetch_env(:ash_bulk_durable, :oban)
    Application.put_env(:ash_bulk_durable, :oban, @oban)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_bulk_durable, :oban, value)
        :error -> Application.delete_env(:ash_bulk_durable, :oban)
      end
    end)

    :ok
  end

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

  defp job_state(bulk_action, prefix) do
    from(j in Oban.Job, where: j.id == ^bulk_action.oban_job_id, select: j.state)
    |> Repo.one(prefix: prefix)
  end

  defp set_job_state(bulk_action, state, attempted_at \\ DateTime.utc_now()) do
    from(j in Oban.Job, where: j.id == ^bulk_action.oban_job_id)
    |> Repo.update_all([set: [state: state, attempted_at: attempted_at]], prefix: @prefix)
  end

  defp prefixed_job(bulk_action),
    do: Repo.get!(Oban.Job, bulk_action.oban_job_id, prefix: @prefix)

  defp put_worker_lost_after(ms) do
    previous = Application.fetch_env(:ash_bulk_durable, :worker_lost_after)
    Application.put_env(:ash_bulk_durable, :worker_lost_after, ms)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_bulk_durable, :worker_lost_after, value)
        :error -> Application.delete_env(:ash_bulk_durable, :worker_lost_after)
      end
    end)
  end

  defp reload(%BulkAction{id: id}), do: Ash.get!(BulkAction, id, authorize?: false)

  test "the job is enqueued under the instance's prefix" do
    bulk_action = create_bulk_action!()

    assert job_state(bulk_action, @prefix) == "available"
    assert job_state(bulk_action, "public") == nil
  end

  test "the sweep leaves a bulk action with a live prefixed job untouched" do
    bulk_action = create_bulk_action!()

    refute RescueStuckBulkActions.worker_lost?(bulk_action)
    assert :ok = RescueStuckBulkActions.perform(%Oban.Job{})

    fresh = reload(bulk_action)
    assert fresh.status == :queued
    assert is_nil(fresh.finished_at)
    assert job_state(bulk_action, @prefix) == "available"
  end

  test "a freshly picked-up :executing prefixed job is not lost" do
    bulk_action = create_bulk_action!()
    set_job_state(bulk_action, "executing")

    refute RescueStuckBulkActions.worker_lost?(reload(bulk_action))
  end

  test "a bulk action whose prefixed job is :discarded is still rescued" do
    bulk_action = create_bulk_action!()
    set_job_state(bulk_action, "discarded")

    assert :ok = RescueStuckBulkActions.perform(%Oban.Job{})

    fresh = reload(bulk_action)
    assert fresh.status == :failed
    assert fresh.result["reason"] == "worker_lost"
  end

  test "a silent :executing prefixed job is rescued and cancelled in its own table" do
    bulk_action = create_bulk_action!()
    set_job_state(bulk_action, "executing", DateTime.add(DateTime.utc_now(), -1, :hour))

    assert :ok = RescueStuckBulkActions.perform(%Oban.Job{})

    fresh = reload(bulk_action)
    assert fresh.status == :failed
    assert fresh.result["reason"] == "worker_lost"
    assert job_state(bulk_action, @prefix) == "cancelled"
  end

  test "a heartbeat lands on the prefixed job row" do
    # Beats every 10ms, so a 100ms run beats several times.
    put_worker_lost_after(100)
    bulk_action = create_bulk_action!()
    set_job_state(bulk_action, "executing")

    Heartbeat.beating(prefixed_job(bulk_action), fn -> Process.sleep(100) end)

    assert is_integer(prefixed_job(bulk_action).meta["heartbeat_at"])
  end
end
