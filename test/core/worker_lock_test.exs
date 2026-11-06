defmodule AshBulkDurable.Core.WorkerLockTest do
  @moduledoc """
  The worker's chunks, recovery and verdicts under the bulk action lock. A
  lock held by another transaction, a second worker, and a write that
  survives the worker's rollback all need connections of their own, so this
  test runs outside the sandbox and deletes what it wrote.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: AshBulkDurable.Test.Repo

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshBulkDurable.Core.Worker
  alias AshBulkDurable.Test.{BulkAction, Region, Repo, Row, Scope, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    tag = "wlock#{System.unique_integer([:positive])}"

    user = create_user!(tag)
    on_exit(fn -> cleanup(tag) end)
    %{user: user, scope: Scope.new(actor: user), tag: tag}
  end

  defp submit!(ctx, count, opts \\ []) do
    inputs =
      Enum.map(1..count, fn i ->
        %{code: "#{ctx.tag}-#{i}", name: "#{ctx.tag} N#{i}", native_name: "#{ctx.tag} A#{i}"}
      end)

    {:ok, bulk_action} =
      AshBulkDurable.bulk_create(
        inputs,
        Region,
        :create,
        Keyword.merge([scope: ctx.scope, chunk_size: 1], opts)
      )

    bulk_action
  end

  # A region the bulk action's row `i` would create already exists, so it fails.
  defp taken!(ctx, i) do
    Ash.create!(
      Region,
      %{code: "#{ctx.tag}-#{i}", name: "#{ctx.tag} X#{i}", native_name: "X#{i}"},
      authorize?: false
    )
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp statuses(bulk_action), do: Enum.map(rows(bulk_action), & &1.status)

  defp reload(bulk_action), do: Ash.get!(BulkAction, bulk_action.id, authorize?: false)

  # The codes of the regions the bulk action created, as many times as each was.
  defp created(ctx) do
    %{rows: rows} =
      Repo.query!("SELECT code FROM regions WHERE code LIKE $1 || '-%' AND name NOT LIKE '%X%'", [
        ctx.tag
      ])

    rows |> List.flatten() |> Enum.sort()
  end

  defp codes(ctx, range), do: Enum.map(range, &"#{ctx.tag}-#{&1}")

  # As queued, nothing run: no verdict, nothing done.
  defp assert_untouched(bulk_action) do
    assert %{status: :queued, result: nil, finished_at: nil, started_at: nil, rows_done: 0} =
             reload(bulk_action)
  end

  defp job(bulk_action), do: Repo.get!(Oban.Job, bulk_action.oban_job_id)

  defp perform_as_current(bulk_action) do
    Worker
    |> build_job(%{"bulk_action_id" => bulk_action.id})
    |> Map.put(:id, bulk_action.oban_job_id)
    |> perform_job()
  end

  describe "exclusion" do
    test "a run while another transaction holds the bulk action writes nothing", ctx do
      bulk_action = submit!(ctx, 2)
      locker = lock_elsewhere(bulk_action.id)

      assert :ok = perform_as_current(bulk_action)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_untouched(bulk_action)
    end

    test "all or nothing: the same", ctx do
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      locker = lock_elsewhere(bulk_action.id)

      assert :ok = perform_as_current(bulk_action)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_untouched(bulk_action)
    end
  end

  describe "two runs of one bulk action" do
    test "taking turns chunk by chunk, apply every row once and write one verdict", ctx do
      bulk_action = submit!(ctx, 4)
      test_pid = self()
      handler = "turns-#{ctx.tag}"

      # After each chunk commits, its run waits for its turn.
      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :chunk, :stop],
        fn _event, _measurements, %{bulk_action_id: id}, _config ->
          if id == bulk_action.id do
            send(test_pid, {:committed, self()})
            receive do: (:go -> :ok)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      job = job(bulk_action)
      a = start_run(job)
      assert_receive {:committed, ^a}, 5_000
      b = start_run(job)
      assert_receive {:committed, ^b}, 5_000
      send(a, :go)
      assert_receive {:committed, ^a}, 5_000
      send(b, :go)
      # B's last chunk wrote the last row, and committed the verdict with it.
      assert_receive {:committed, ^b}, 5_000
      assert %{status: :completed} = reload(bulk_action)
      send(a, :go)
      assert_receive {:done, ^a, :ok}, 5_000
      send(b, :go)
      assert_receive {:done, ^b, :ok}, 5_000

      assert statuses(bulk_action) == List.duplicate(:succeeded, 4)
      assert created(ctx) == codes(ctx, 1..4)

      assert %{status: :completed, rows_done: 4, result: %{"outcome" => "completed"}} =
               reload(bulk_action)
    end

    test "one starting while the other is inside a chunk writes nothing, and the other finishes",
         ctx do
      bulk_action = submit!(ctx, 2)
      job = job(bulk_action)
      test_pid = self()

      # Inside A's first chunk, under its lock: B runs to its end.
      at_first_chunk(bulk_action, fn ->
        b = start_run(job)
        assert_receive {:done, ^b, :ok}, 5_000
        send(test_pid, :b_done)
      end)

      assert :ok = perform_as_current(bulk_action)
      assert_received :b_done

      assert statuses(bulk_action) == [:succeeded, :succeeded]
      assert created(ctx) == codes(ctx, 1..2)
      assert %{status: :completed, rows_done: 2} = reload(bulk_action)
    end

    test "a run that finds every row done writes the verdict, once", ctx do
      bulk_action = submit!(ctx, 1)
      assert :ok = perform_as_current(bulk_action)
      finished = reload(bulk_action)
      assert finished.status == :completed

      # As a run that wrote the last row and died before its verdict leaves it.
      id = Ecto.UUID.dump!(bulk_action.id)

      Repo.query!(
        "UPDATE bulk_actions SET status = 'running', result = NULL, finished_at = NULL WHERE id = $1",
        [id]
      )

      assert :ok = perform_as_current(bulk_action)
      assert %{status: :completed, rows_done: 1} = again = reload(bulk_action)
      assert again.finished_at

      # A second run, past its own read of the bulk action when the verdict
      # lands, finds it no longer running and leaves it as it is.
      Repo.query!(
        "UPDATE bulk_actions SET status = 'running', result = NULL, finished_at = NULL WHERE id = $1",
        [id]
      )

      handler = "verdict-#{ctx.tag}"

      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :worker_attempt, :start],
        fn _event, _measurements, %{bulk_action_id: bulk_action_id}, _config ->
          if bulk_action_id == bulk_action.id do
            Repo.query!(
              "UPDATE bulk_actions SET status = 'completed_with_errors', " <>
                "result = '{\"outcome\": \"elsewhere\"}', finished_at = now() WHERE id = $1",
              [id]
            )
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = perform_as_current(bulk_action)
      :telemetry.detach(handler)

      assert %{status: :completed_with_errors, result: %{"outcome" => "elsewhere"}} =
               reload(bulk_action)
    end
  end

  describe "a run killed in the middle of a chunk" do
    test "commits nothing of it, and the next run resumes from the rows", ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      short_name = Ash.Domain.Info.short_name(AshBulkDurable.Test.Domain)
      handler = "kill-#{ctx.tag}"

      # The first target is written, the second not yet, nothing committed.
      :telemetry.attach(
        handler,
        [:ash, short_name, :create, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata[:resource_short_name] == :region and Process.get(:run?),
            do: Process.exit(self(), :kill)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      job = job(bulk_action)

      {pid, monitor} =
        spawn_monitor(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          Process.put(:run?, true)
          Worker.perform(job)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      :telemetry.detach(handler)

      assert created(ctx) == []
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert_untouched(bulk_action)

      # Its lock went with its connection.
      assert eventually(fn -> lockable?(bulk_action.id) end)

      assert :ok = perform_as_current(bulk_action)
      assert statuses(bulk_action) == [:succeeded, :succeeded]
      assert created(ctx) == codes(ctx, 1..2)
      assert %{status: :completed, rows_done: 2} = reload(bulk_action)
    end
  end

  describe "a failed chunk's recovery" do
    # Row 2's code is taken, so a chunk holding it rolls back, and recovery
    # runs its rows one at a time. The `:run` batches end in order: the
    # chunk's, then each recovered row's.

    test "stops at the first lock another transaction holds, writing nothing more", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 3, chunk_size: 3)
      locker = lock_after_batch(bulk_action, 2)
      locks = count_locks()

      assert :ok = perform_as_current(bulk_action)

      # The chunk's, row 1's, and row 2's refused one: row 3 is not tried.
      assert locks.() == 3
      release(locker)
      assert statuses(bulk_action) == [:succeeded, :resolved, :resolved]
      assert created(ctx) == codes(ctx, [1])

      # The next run recovers the rest: row 2 fails alone.
      assert :ok = perform_as_current(bulk_action)
      assert statuses(bulk_action) == [:succeeded, :failed, :succeeded]
      assert created(ctx) == codes(ctx, [1, 3])
      assert %{status: :completed_with_errors, rows_done: 2} = reload(bulk_action)
    end

    test "skips a row another run applied since the chunk read it, and goes on", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 3, chunk_size: 3)
      [_r1, _r2, r3] = rows(bulk_action)
      after_batch(1, fn -> apply_elsewhere(r3) end)

      assert :ok = perform_as_current(bulk_action)

      assert [
               %{status: :succeeded},
               %{status: :failed},
               %{status: :succeeded, record_id: "other"}
             ] = rows(bulk_action)

      assert created(ctx) == codes(ctx, [1])
      assert %{status: :completed_with_errors, rows_done: 1} = reload(bulk_action)
    end

    test "marks a failed row only while it is still :resolved under the lock", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      [_r1, r2] = rows(bulk_action)

      # After row 2's own batch rolls back, and before the worker marks it, a
      # retry reopens it.
      after_batch(3, fn -> reopen_elsewhere(r2) end)

      assert :ok = perform_as_current(bulk_action)

      assert [%{status: :succeeded}, %{status: :pending, error: nil}] = rows(bulk_action)
    end

    test "marks a failed row only under the lock", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      locker = lock_after_batch(bulk_action, 3)

      assert :ok = perform_as_current(bulk_action)

      release(locker)
      assert [%{status: :succeeded}, %{status: :resolved, error: nil}] = rows(bulk_action)
      assert %{status: :running, result: nil, rows_done: 1} = reload(bulk_action)
    end
  end

  describe "all or nothing, rolled back" do
    test "writes its verdict under the lock: not while another transaction holds it", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      locker = lock_after_batch(bulk_action, 1)

      assert :ok = perform_as_current(bulk_action)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_untouched(bulk_action)

      assert :ok = perform_as_current(bulk_action)
      assert created(ctx) == []

      assert %{status: :failed, result: %{"reason" => "atomic_chunk_rolled_back"}} =
               reload(bulk_action)
    end
  end

  # Part 1's compare-and-set still catches a write that slips past the lock,
  # here one from a connection that never takes it.
  describe "a row moved on under another run" do
    test "phase 2, per row: the chunk rolls back with no recovery, and a superseded job cancels",
         ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      [_r1, r2] = rows(bulk_action)
      at_first_chunk(bulk_action, fn -> apply_elsewhere(r2) end)
      spans = count_chunk_events(bulk_action)

      log =
        capture_log(fn ->
          assert {:cancel, :superseded} =
                   perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
        end)

      assert log =~ "is superseded"
      assert spans.() == %{start: 1, stop: 0, exception: 1}

      # Row 1's target write and flip shared the refused flip's transaction.
      assert created(ctx) == []
      assert [%{status: :resolved}, %{status: :succeeded, record_id: "other"}] = rows(bulk_action)
      assert_untouched(bulk_action)
    end

    test "phase 2, all or nothing: the transaction rolls back, no rollback verdict, and the current job snoozes",
         ctx do
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      [_r1, r2] = rows(bulk_action)
      at_first_chunk(bulk_action, fn -> apply_elsewhere(r2) end)
      spans = count_chunk_events(bulk_action)

      log = capture_log(fn -> assert {:snooze, 30} = perform_as_current(bulk_action) end)

      assert log =~ "a stale run wrote a row first"
      assert spans.() == %{start: 1, stop: 0, exception: 1}
      assert created(ctx) == []
      assert [%{status: :resolved}, %{status: :succeeded, record_id: "other"}] = rows(bulk_action)
      assert_untouched(bulk_action)
    end

    test "phase 2, per row: a row another run applied before recovery marks it failed is left as it is",
         ctx do
      # Row 2's code is taken, so the chunk rolls back and recovery runs the
      # rows one at a time.
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      [_r1, r2] = rows(bulk_action)

      # The `:run` batches end in this order: the chunk, then recovery's row 1
      # and row 2. After row 2's, and before the worker marks it failed, the
      # other run applies it: the mark reads it again under the lock, and
      # leaves it.
      after_batch(3, fn -> apply_elsewhere(r2) end)
      spans = count_chunk_events(bulk_action)

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
      assert spans.() == %{start: 1, stop: 1, exception: 0}

      # Row 1 committed alone before; row 2 keeps the other run's write.
      assert [%{status: :succeeded}, %{status: :succeeded, record_id: "other", error: nil}] =
               rows(bulk_action)

      assert created(ctx) == codes(ctx, [1])
      assert %{status: :completed_with_errors, rows_done: 1} = reload(bulk_action)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # A run of `job` in a process of its own, as another node's would be.
  defp start_run(job) do
    test_pid = self()

    spawn_link(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      send(test_pid, {:done, self(), Worker.perform(job)})
    end)
  end

  # Runs `fun` once, in the run's own process, when its first chunk starts:
  # after it read the chunk under the lock, before it writes it.
  defp at_first_chunk(bulk_action, fun) do
    handler = "at-first-chunk-#{bulk_action.id}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :chunk, :start],
      fn _event, _measurements, %{bulk_action_id: id}, _config ->
        if id == bulk_action.id do
          :telemetry.detach(handler)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Another run's write of `row`, committed on a connection of its own.
  defp apply_elsewhere(row),
    do: write_elsewhere(row, "status = 'succeeded', record_id = 'other'")

  # A retry's reopening of `row`, the same way.
  defp reopen_elsewhere(row), do: write_elsewhere(row, "status = 'pending'")

  defp write_elsewhere(row, set) do
    Task.async(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      Repo.query!("UPDATE bulk_action_rows SET #{set} WHERE id = $1", [
        Ecto.UUID.dump!(row.id)
      ])
    end)
    |> Task.await()
  end

  # Runs `fun` in the run's own process when its `n`th `:run` batch ends,
  # still inside that batch's transaction, whether it commits or rolls back.
  defp after_batch(n, fun) do
    short_name = Ash.Domain.Info.short_name(AshBulkDurable.Test.BulkActions)
    handler = "after-batch-#{System.unique_integer([:positive])}"
    counter = :counters.new(1, [])

    :telemetry.attach(
      handler,
      [:ash, short_name, :bulk_update, :stop],
      fn _event, _measurements, metadata, _config ->
        if metadata[:action] == :run and :counters.add(counter, 1, 1) == :ok and
             :counters.get(counter, 1) == n do
          :telemetry.detach(handler)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # From the end of the run's `n`th `:run` batch, another connection waits for
  # the bulk action's lock: it holds it from the moment that batch's
  # transaction ends, until told.
  defp lock_after_batch(bulk_action, n) do
    test_pid = self()

    after_batch(n, fn ->
      send(test_pid, {:locker, lock_elsewhere(bulk_action.id, wait?: true)})
      assert eventually(&waiting_for_lock?/0)
    end)

    fn ->
      assert_received {:locker, locker}
      locker
    end
  end

  # The bulk action locks the test process (the run, under `perform_job`)
  # tried to take.
  defp count_locks do
    test_pid = self()
    counter = :counters.new(1, [])
    handler = "count-locks-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :test, :repo, :query],
      fn _event, _measurements, %{source: source, query: query}, _config ->
        if self() == test_pid and source == "bulk_actions" and
             String.contains?(query, "SKIP LOCKED"),
           do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fn -> :counters.get(counter, 1) end
  end

  # How many of the bulk action's chunk spans started, stopped and raised.
  defp count_chunk_events(bulk_action) do
    counters = :counters.new(3, [])
    index = %{start: 1, stop: 2, exception: 3}
    handler = "chunk-events-#{bulk_action.id}"

    :telemetry.attach_many(
      handler,
      for(kind <- [:start, :stop, :exception], do: [:ash_bulk_durable, :chunk, kind]),
      fn [_, _, kind], _measurements, %{bulk_action_id: id}, _config ->
        if id == bulk_action.id, do: :counters.add(counters, index[kind], 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fn -> Map.new(index, fn {kind, i} -> {kind, :counters.get(counters, i)} end) end
  end

  defp waiting_for_lock? do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' " <>
          "AND query LIKE '%FOR NO KEY UPDATE%'"
      )

    count > 0
  end

  # Holds the bulk action's row lock from a connection of its own until told.
  # With `wait?: true` it waits for the lock rather than for having it.
  defp lock_elsewhere(id, opts \\ []) do
    test_pid = self()

    pid =
      spawn(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM bulk_actions WHERE id = $1 FOR NO KEY UPDATE", [
            Ecto.UUID.dump!(id)
          ])

          send(test_pid, :locked)

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end)

        send(test_pid, :released)
      end)

    unless opts[:wait?], do: assert_receive(:locked, 2_000)
    pid
  end

  defp release(locker) when is_function(locker), do: release(locker.())

  defp release(locker) do
    send(locker, :release)
    assert_receive :released, 2_000
  end

  defp lockable?(id) do
    {:ok, locked} =
      Repo.transaction(fn ->
        Repo.query!("SELECT 1 FROM bulk_actions WHERE id = $1 FOR NO KEY UPDATE SKIP LOCKED", [
          Ecto.UUID.dump!(id)
        ]).num_rows == 1
      end)

    locked
  end

  defp eventually(fun, tries \\ 250) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp create_user!(tag) do
    Ash.create!(User, %{name: "Lock", email: "#{tag}@example.test"},
      action: :create_super,
      authorize?: false
    )
  end

  # Every user the test made has an email ending in its tag, and every region
  # a code starting with it.
  defp cleanup(tag) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    users = "SELECT id FROM users WHERE email LIKE '%' || $1"
    email = "#{tag}@example.test"

    Repo.query!(
      "DELETE FROM oban_jobs WHERE args->>'bulk_action_id' IN " <>
        "(SELECT id::text FROM bulk_actions WHERE user_id IN (#{users}))",
      [email]
    )

    Repo.query!("DELETE FROM bulk_actions WHERE user_id IN (#{users})", [email])
    Repo.query!("DELETE FROM regions WHERE code LIKE $1 || '-%'", [tag])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [email])
  end
end
