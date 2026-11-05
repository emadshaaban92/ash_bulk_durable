defmodule AshBulkDurable.Core.PurgeStaleStagingTest do
  @moduledoc """
  Tests for the companion-staging GC. Runs the sweep against the in-memory
  `AshBulkDurable.TestStorage` adapter so deletions are observable without a
  real bucket.

  `async: false` — swaps the `:ash_bulk_durable` storage adapter globally.
  """
  use AshBulkDurable.DataCase, async: false

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
  defp create_bulk_action!(file_names) do
    user_id = Ecto.UUID.generate()

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

      assert :ok = PurgeStaleStaging.sweep()

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

      assert :ok = PurgeStaleStaging.sweep()

      remaining = TestStorage.keys()
      assert key_parked in remaining
      refute key_orphan in remaining
    end

    test "keeps keys younger than 24h even when they are orphans" do
      fresh_orphan = "#{@prefix}#{Ecto.UUID.generate()}/uuid-d/companions/logo.zip"
      TestStorage.put(fresh_orphan, "x", DateTime.utc_now())

      assert :ok = PurgeStaleStaging.sweep()

      assert fresh_orphan in TestStorage.keys()
    end

    test "keeps keys for :queued / :running bulk actions regardless of age" do
      {_queued, [key]} = create_bulk_action!(["logo.zip"])
      TestStorage.put(key, "x", old())

      assert :ok = PurgeStaleStaging.sweep()

      assert key in TestStorage.keys()
    end

    # The sweep's preserve-set is built from bulk actions in
    # `[:queued, :running, :completed_with_errors]`, and those that failed in
    # the last day. A bulk action that's left a stale staging blob behind,
    # failed more than a day ago or cancelled, must still be cleaned up.
    test "deletes keys for :failed and :cancelled bulk actions (read excludes them)" do
      {failed, [key_failed]} = create_bulk_action!(["logo.zip"])
      finish!(failed, {:failed, %{reason: :resolver_prepare_error}})
      failed_at!(failed, old())

      {cancelled, [key_cancelled]} = create_bulk_action!(["logo.zip"])
      finish!(cancelled, :cancelled)

      TestStorage.put(key_failed, "x", old())
      TestStorage.put(key_cancelled, "x", old())

      assert :ok = PurgeStaleStaging.sweep()

      remaining = TestStorage.keys()
      refute key_failed in remaining
      refute key_cancelled in remaining
    end

    # Retryable for a day from when it failed, not from when its files went
    # up: an upload a day old that failed an hour ago keeps its files.
    test "keeps keys of a bulk action that failed less than a day ago" do
      {failed, [key]} = create_bulk_action!(["logo.zip"])
      finish!(failed, {:failed, %{reason: :resolver_prepare_error}})
      TestStorage.put(key, "x", old())

      assert :ok = PurgeStaleStaging.sweep()

      assert key in TestStorage.keys()
    end
  end

  defp failed_at!(bulk_action, at) do
    AshBulkDurable.Test.Repo.query!("UPDATE bulk_actions SET finished_at = $1 WHERE id = $2", [
      DateTime.to_naive(at),
      Ecto.UUID.dump!(bulk_action.id)
    ])
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

    test "abandoning a bulk action deletes its keys once the cancel commits" do
      {bulk_action, [key]} = create_bulk_action!(["a.zip"])
      TestStorage.put(key)

      bulk_action |> finish!(:completed_with_errors) |> finish!(:cancelled)

      refute key in TestStorage.keys()
    end

    test "delete_bulk_action_staging/1 is a no-op for an unknown bulk action" do
      assert :ok = PurgeStaleStaging.delete_bulk_action_staging(Ecto.UUID.generate())
    end
  end
end
