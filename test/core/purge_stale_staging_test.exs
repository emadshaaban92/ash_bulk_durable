defmodule AshBulkDurable.Core.PurgeStaleStagingTest do
  @moduledoc """
  Tests for the companion-staging GC: the sweep (through `sweep/0`, and
  through `Oban.Testing.perform_job/3` while the module is still the
  crontab's worker) and the delete that abandoning does itself, against the in-memory
  `AshBulkDurable.TestStorage` adapter so deletions are observable without a
  real bucket.

  `async: false` — swaps the `:ash_bulk_durable` storage adapter globally.
  """
  use AshBulkDurable.DataCase, async: false
  use Oban.Testing, repo: AshBulkDurable.Test.Repo

  import ExUnit.CaptureLog

  alias AshBulkDurable.Core.PurgeStaleStaging
  alias AshBulkDurable.TestStorage
  alias AshBulkDurable.Test.BulkAction

  @prefix "bulk-staging/"
  @day_seconds 24 * 60 * 60

  setup do
    AshBulkDurable.StorageHelpers.put_config(:storage, TestStorage)

    start_supervised!(TestStorage)
    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  # Staged files live under `bulk-staging/<user_id>/`, so build their keys
  # from the bulk action's own user_id.
  defp create_bulk_action!(file_names, user_id \\ Ecto.UUID.generate()) do
    staged_files =
      file_names
      |> Enum.with_index()
      |> Map.new(fn {file, idx} ->
        {"file_#{idx}", "#{@prefix}#{user_id}/uuid-#{idx}/companions/#{file}"}
      end)

    bulk_action =
      Ash.create!(
        BulkAction,
        %{
          user_id: user_id,
          resource_name: "AshBulkDurable.Test.Region",
          action_name: :create,
          action_type: :create,
          staged_files: staged_files,
          total_rows: 1,
          mode: :per_row,
          chunk_size: 50,
          rows: [%{input: %{name: "X"}}]
        },
        action: :create,
        authorize?: false
      )

    {bulk_action, Map.values(staged_files)}
  end

  defp finish!(bulk_action, result) do
    Ash.update!(bulk_action, %{result: result}, action: :mark_finished, authorize?: false)
  end

  # Moves `finished_at` back by `seconds`, as if the bulk action had
  # finished that long ago.
  defp finished_ago!(bulk_action, seconds) do
    AshBulkDurable.Test.Repo.query!(
      "UPDATE bulk_actions SET finished_at = now() - make_interval(secs => $1) WHERE id = $2",
      [seconds, Ecto.UUID.dump!(bulk_action.id)]
    )
  end

  defp old, do: DateTime.add(DateTime.utc_now(), -(@day_seconds + 60), :second)

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "daily sweep" do
    test "deletes orphan + terminal staging keys, keeps :completed_with_errors keys" do
      key_orphan = "#{@prefix}#{Ecto.UUID.generate()}/uuid-a/companions/logo.zip"

      {completed, [key_completed]} = create_bulk_action!(["logo.zip"])
      finish!(completed, :completed)

      {with_errors, [key_with_errors]} = create_bulk_action!(["logo.zip"])
      finish!(with_errors, :completed_with_errors)

      TestStorage.put(key_orphan, "x", old())
      TestStorage.put(key_completed, "x", old())
      TestStorage.put(key_with_errors, "x", old())

      assert :ok = perform_job(PurgeStaleStaging, %{})

      remaining = TestStorage.keys()
      refute key_orphan in remaining
      refute key_completed in remaining
      assert key_with_errors in remaining
    end

    test "still runs, and keeps its keys, past a bulk action whose action is gone" do
      {parked, [key_parked]} = create_bulk_action!(["logo.zip"])
      finish!(parked, :completed_with_errors)

      AshBulkDurable.Test.Repo.query!("UPDATE bulk_actions SET action_name = $1 WHERE id = $2", [
        "gone_#{System.unique_integer([:positive])}",
        Ecto.UUID.dump!(parked.id)
      ])

      key_orphan = "#{@prefix}#{Ecto.UUID.generate()}/uuid-a/companions/logo.zip"
      TestStorage.put(key_parked, "x", old())
      TestStorage.put(key_orphan, "x", old())

      assert :ok = perform_job(PurgeStaleStaging, %{})

      remaining = TestStorage.keys()
      assert key_parked in remaining
      refute key_orphan in remaining
    end

    test "keeps keys younger than 24h even when they are orphans" do
      fresh_orphan = "#{@prefix}#{Ecto.UUID.generate()}/uuid-d/companions/logo.zip"
      TestStorage.put(fresh_orphan, "x", DateTime.utc_now())

      assert :ok = perform_job(PurgeStaleStaging, %{})

      assert fresh_orphan in TestStorage.keys()
    end

    test "keeps keys for :queued / :running bulk actions regardless of age" do
      {_queued, [key]} = create_bulk_action!(["logo.zip"])
      TestStorage.put(key, "x", old())

      assert :ok = perform_job(PurgeStaleStaging, %{})

      assert key in TestStorage.keys()
    end

    # The sweep's preserve-set is built from bulk actions in
    # `[:queued, :running, :completed_with_errors]`, plus `:failed` ones that
    # finished within the day. A bulk action that's left a stale staging blob
    # behind in :cancelled, or in :failed for over a day, must still be
    # cleaned up.
    test "deletes keys for :cancelled bulk actions and long-:failed ones" do
      {failed, [key_failed]} = create_bulk_action!(["logo.zip"])
      finish!(failed, {:failed, %{reason: :resolver_prepare_error}})
      finished_ago!(failed, @day_seconds + 60 * 60)

      {cancelled, [key_cancelled]} = create_bulk_action!(["logo.zip"])
      finish!(cancelled, :cancelled)

      TestStorage.put(key_failed, "x", old())
      TestStorage.put(key_cancelled, "x", old())

      assert :ok = perform_job(PurgeStaleStaging, %{})

      remaining = TestStorage.keys()
      refute key_failed in remaining
      refute key_cancelled in remaining
    end

    test "sweep/0 keeps a :failed bulk action's old files for a day after it failed" do
      {failed, [key]} = create_bulk_action!(["logo.zip"])
      finish!(failed, {:failed, %{reason: :worker_lost}})
      finished_ago!(failed, @day_seconds - 60 * 60)
      TestStorage.put(key, "x", old())

      assert :ok = PurgeStaleStaging.sweep()

      assert key in TestStorage.keys()
    end

    test "sweep/0 deletes a :failed bulk action's files once it failed over a day ago" do
      {failed, [key]} = create_bulk_action!(["logo.zip"])
      finish!(failed, {:failed, %{reason: :worker_lost}})
      finished_ago!(failed, @day_seconds + 60 * 60)
      TestStorage.put(key, "x", old())

      assert :ok = PurgeStaleStaging.sweep()

      refute key in TestStorage.keys()
    end

    test "sweep/0 keeps :queued, :running and :completed_with_errors keys, deletes the rest" do
      {_queued, [key_queued]} = create_bulk_action!(["logo.zip"])

      {running, [key_running]} = create_bulk_action!(["logo.zip"])
      Ash.update!(running, %{}, action: :mark_running, authorize?: false)

      {with_errors, [key_with_errors]} = create_bulk_action!(["logo.zip"])
      finish!(with_errors, :completed_with_errors)

      {completed, [key_completed]} = create_bulk_action!(["logo.zip"])
      finish!(completed, :completed)

      {cancelled, [key_cancelled]} = create_bulk_action!(["logo.zip"])
      cancelled |> finish!(:completed_with_errors) |> finish!(:cancelled)

      key_orphan = "#{@prefix}#{Ecto.UUID.generate()}/uuid-a/companions/logo.zip"

      keys = [key_queued, key_running, key_with_errors, key_completed, key_cancelled, key_orphan]
      for key <- keys, do: TestStorage.put(key, "x", old())

      assert :ok = PurgeStaleStaging.sweep()

      remaining = TestStorage.keys()
      assert key_queued in remaining
      assert key_running in remaining
      assert key_with_errors in remaining
      refute key_completed in remaining
      refute key_cancelled in remaining
      refute key_orphan in remaining
    end
  end

  describe "eager one-shot" do
    test "delete_bulk_action_staging/1 removes every key for the bulk action synchronously" do
      {bulk_action, [key_one, key_two]} = create_bulk_action!(["a.zip", "b.zip"])
      {_other_bulk_action, [other]} = create_bulk_action!(["keep.zip"])

      TestStorage.put(key_one)
      TestStorage.put(key_two)
      TestStorage.put(other)

      assert :ok = PurgeStaleStaging.delete_bulk_action_staging(bulk_action.id)

      remaining = TestStorage.keys()
      refute key_one in remaining
      refute key_two in remaining
      assert other in remaining
    end

    test "delete_staging/1 deletes the record's keys without reading it again" do
      {bulk_action, [key]} = create_bulk_action!(["a.zip"])
      TestStorage.put(key)

      Ash.destroy!(bulk_action, authorize?: false)

      assert :ok = PurgeStaleStaging.delete_staging(bulk_action)
      refute key in TestStorage.keys()
    end

    test "delete_bulk_action_staging/1 is a no-op for an unknown bulk action" do
      assert :ok = PurgeStaleStaging.delete_bulk_action_staging(Ecto.UUID.generate())
    end
  end

  describe "abandon/2" do
    defmodule RaisingStorage do
      @moduledoc false
      @behaviour AshBulkDurable.Core.Storage

      @impl true
      def get_object(_key), do: {:error, :not_found}

      @impl true
      def delete_object(_key), do: raise("storage is down")

      @impl true
      def list_objects(_prefix), do: {:ok, []}
    end

    setup %{super_user: user} do
      {bulk_action, keys} = create_bulk_action!(["a.zip", "b.zip"], user.id)
      parked = finish!(bulk_action, :completed_with_errors)
      Enum.each(keys, &TestStorage.put/1)

      %{
        bulk_action: parked,
        keys: keys,
        scope: AshBulkDurable.Test.Scope.new(actor: user)
      }
    end

    test "deletes the staged files once the cancel commits, enqueueing nothing", ctx do
      assert {:ok, %{status: :cancelled}} =
               AshBulkDurable.abandon(ctx.bulk_action, scope: ctx.scope)

      remaining = TestStorage.keys()
      for key <- ctx.keys, do: refute(key in remaining)
      assert all_enqueued(worker: PurgeStaleStaging) == []
    end

    test "inside a caller's transaction, leaves the files for the sweep", ctx do
      assert {:ok, {:ok, %{status: :cancelled}}} =
               AshBulkDurable.Test.Repo.transaction(fn ->
                 result = AshBulkDurable.abandon(ctx.bulk_action, scope: ctx.scope)
                 for key <- ctx.keys, do: assert(key in TestStorage.keys())
                 result
               end)

      remaining = TestStorage.keys()
      for key <- ctx.keys, do: assert(key in remaining)
      assert all_enqueued(worker: PurgeStaleStaging) == []
    end

    test "still cancels when storage raises, and logs a warning", ctx do
      AshBulkDurable.StorageHelpers.put_config(:storage, RaisingStorage)

      log =
        capture_log(fn ->
          assert {:ok, %{status: :cancelled}} =
                   AshBulkDurable.abandon(ctx.bulk_action, scope: ctx.scope)
        end)

      assert log =~ "[warning]"
      assert log =~ ctx.bulk_action.id
      assert Ash.get!(BulkAction, ctx.bulk_action.id, authorize?: false).status == :cancelled
    end
  end
end
