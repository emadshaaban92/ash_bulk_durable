defmodule AshBulkDurable.Core.TelemetryTest do
  @moduledoc """
  Verifies the telemetry events fire at the documented sites with the
  documented measurement / metadata shapes. A handler attached in the test
  process forwards every event to the mailbox (the worker runs inline under
  `perform_job/3`, so the emits land here).
  """
  use AshBulkDurable.DataCase, async: true
  use Oban.Testing, repo: AshBulkDurable.Test.Repo

  alias AshBulkDurable.Core.Worker
  alias AshBulkDurable.Test.BulkAction
  alias AshBulkDurable.Test.Region

  @events [
    [:ash_bulk_durable, :worker_attempt, :start],
    [:ash_bulk_durable, :bulk_action, :start],
    [:ash_bulk_durable, :bulk_action, :stop],
    [:ash_bulk_durable, :staged_files_download, :stop],
    [:ash_bulk_durable, :phase1, :start],
    [:ash_bulk_durable, :phase1, :stop],
    [:ash_bulk_durable, :chunk, :start],
    [:ash_bulk_durable, :chunk, :stop]
  ]

  setup do
    test_pid = self()
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

    # The handler is registered globally, so under async other modules'
    # workers emit these same events concurrently. Forward every event and
    # let each `assert_receive` select its own bulk action by pinning `bulk_action_id` in the
    # metadata pattern — every telemetry event carries `bulk_action_id`, and the id is a
    # per-bulk-action UUID, so this filters cross-talk regardless of which process
    # emitted the event (including off-process phase-1 resolve children).
    :telemetry.attach_many(
      handler_id,
      @events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp create_bulk_action!(rows, chunk_size, user_id, mode \\ :per_row) do
    Ash.create!(
      BulkAction,
      %{
        user_id: user_id,
        resource_name: "AshBulkDurable.Test.Region",
        action_name: :create,
        action_type: :create,
        total_rows: length(rows),
        mode: mode,
        chunk_size: chunk_size,
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  # `Region.code`, `Region.name` and `Region.native_name` are all global unique
  # identities; suffix each per bulk action so concurrent async modules creating
  # regions never collide at the index. `native_name` is a reference, so every
  # row goes through the resolve phase.
  defp region_rows(n, suffix) do
    Enum.map(
      1..n,
      &%{
        input: %{
          name: "Region #{&1}-#{suffix}",
          native_name: {:resolve, AshBulkDurable.EchoResolver, "AR #{&1}-#{suffix}"},
          code: "B#{&1}-#{suffix}"
        }
      }
    )
  end

  describe "happy path" do
    test "emits every event with the documented shape", %{super_user: user} do
      suffix = System.unique_integer([:positive])
      bulk_action = create_bulk_action!(region_rows(3, suffix), 50, user.id)
      bulk_action_id = bulk_action.id
      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action_id})

      assert_receive {:telemetry, [:ash_bulk_durable, :worker_attempt, :start], %{system_time: _},
                      %{bulk_action_id: ^bulk_action_id, attempt: 1, pending_rows_at_start: 3}}

      assert_receive {:telemetry, [:ash_bulk_durable, :bulk_action, :start], %{system_time: _},
                      %{
                        bulk_action_id: ^bulk_action_id,
                        total_rows: 3,
                        chunk_size: 50,
                        mode: :per_row,
                        resource_name: _
                      }}

      assert_receive {:telemetry, [:ash_bulk_durable, :staged_files_download, :stop],
                      %{duration: _, file_count: 0, bytes_downloaded: 0},
                      %{bulk_action_id: ^bulk_action_id}}

      assert_receive {:telemetry, [:ash_bulk_durable, :phase1, :start], %{system_time: _},
                      %{bulk_action_id: ^bulk_action_id, rows_to_resolve: 3, concurrency: _}}

      assert_receive {:telemetry, [:ash_bulk_durable, :phase1, :stop],
                      %{duration: _, rows_resolved: 3, rows_failed: 0},
                      %{bulk_action_id: ^bulk_action_id}}

      assert_receive {:telemetry, [:ash_bulk_durable, :chunk, :stop],
                      %{duration: _, rows_in_chunk: 3, rows_succeeded: 3, rows_failed: 0},
                      %{
                        bulk_action_id: ^bulk_action_id,
                        chunk_index: 0,
                        outcome: :ok,
                        recovery: :none
                      }}

      assert_receive {:telemetry, [:ash_bulk_durable, :bulk_action, :stop],
                      %{duration: _, rows_done: 3, rows_failed: 0},
                      %{bulk_action_id: ^bulk_action_id, status: :completed, failure_reason: nil}}
    end
  end

  describe "atomic-mode failure" do
    test "bulk_action :stop carries status :failed / failure_reason :atomic_chunk_rolled_back",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      # Pre-seed a Region matching row 3's code so its create violates the
      # `:code` identity and the single atomic chunk rolls back.
      Ash.create!(
        Region,
        %{code: "B3-#{suffix}", name: "Existing-#{suffix}", native_name: "AR-#{suffix}"},
        actor: user,
        authorize?: false
      )

      bulk_action = create_bulk_action!(region_rows(5, suffix), 5, user.id, :all_or_nothing)
      bulk_action_id = bulk_action.id
      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action_id})

      assert_receive {:telemetry, [:ash_bulk_durable, :bulk_action, :start], _,
                      %{bulk_action_id: ^bulk_action_id, mode: :all_or_nothing}}

      assert_receive {:telemetry, [:ash_bulk_durable, :bulk_action, :stop], _measurements,
                      %{
                        bulk_action_id: ^bulk_action_id,
                        status: :failed,
                        failure_reason: :atomic_chunk_rolled_back
                      }}
    end
  end

  describe "best-effort chunk rollback" do
    test "a chunk :stop reports outcome :rolled_back / recovery :row_by_row",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      Ash.create!(
        Region,
        %{code: "B3-#{suffix}", name: "Existing-#{suffix}", native_name: "AR-#{suffix}"},
        actor: user,
        authorize?: false
      )

      bulk_action = create_bulk_action!(region_rows(5, suffix), 2, user.id)
      bulk_action_id = bulk_action.id
      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action_id})

      assert_receive {:telemetry, [:ash_bulk_durable, :chunk, :stop], %{rows_succeeded: _},
                      %{
                        bulk_action_id: ^bulk_action_id,
                        outcome: :rolled_back,
                        recovery: :row_by_row
                      }}

      assert_receive {:telemetry, [:ash_bulk_durable, :bulk_action, :stop], _,
                      %{bulk_action_id: ^bulk_action_id, status: :completed_with_errors}}
    end
  end
end
