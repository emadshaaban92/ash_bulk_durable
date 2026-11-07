defmodule AshBulkDurable.Core.WorkerLockTest do
  @moduledoc """
  The worker's chunks, recovery and verdicts under the bulk action lock. A
  lock held by another transaction, a second worker, and a write that
  survives the worker's rollback all need connections of their own, so this
  test runs outside the sandbox and deletes what it wrote.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  defmodule EchoResolver do
    @moduledoc "Resolves a value to itself."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context), do: {:ok, value}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule PrepareRefusingResolver do
    @moduledoc "Can't ready its references."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:error, :prepare_refused}

    @impl true
    def resolve(value, nil, _context), do: {:ok, value}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule RefusingResolver do
    @moduledoc "Refuses every reference."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_value, nil, _context),
      do:
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(field: :native_name, message: "refused")}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule UnpreparableResolver do
    @moduledoc """
    Can't be readied, failing its bulk action. In a run told to hold (a test
    pid under `:hold` in its process), it first says so and waits for `:go`.
    """
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context) do
      with pid when is_pid(pid) <- Process.get(:hold) do
        send(pid, {:preparing, self()})
        receive do: (:go -> :ok)
      end

      {:error, :unprepared}
    end

    @impl true
    def resolve(_value, _state, _context), do: {:error, :never}

    @impl true
    def finish(_state), do: :ok
  end

  defmodule HeldResolver do
    @moduledoc """
    Resolves a value to itself, and refuses one ending in "bad". In a run told
    to hold (a test pid under `:hold` in its process), it first says so as it
    readies, the run's rows already read, and waits for `:go`.
    """
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context) do
      with pid when is_pid(pid) <- Process.get(:hold) do
        send(pid, {:preparing, self()})
        receive do: (:go -> :ok)
      end

      {:ok, nil}
    end

    @impl true
    def resolve(value, nil, _context) do
      if String.ends_with?(value, "bad"),
        do:
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(field: :native_name, message: "bad")},
        else: {:ok, value}
    end

    @impl true
    def finish(nil), do: :ok
  end

  alias AshBulkDurable.Core.Worker
  alias AshBulkDurable.Test.{Branch, BulkAction, Region, Repo, Row, Scope, User}

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

  # As the run's start left it: running, no verdict, nothing done.
  defp assert_no_verdict(bulk_action) do
    assert %{status: :running, result: nil, finished_at: nil, rows_done: 0} =
             running = reload(bulk_action)

    assert running.started_at
  end

  describe "exclusion" do
    test "a run while another transaction holds the bulk action writes nothing", ctx do
      bulk_action = submit!(ctx, 2)
      locker = lock_elsewhere(bulk_action.id)

      assert :busy = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_untouched(bulk_action)
    end

    test "a run stops before phase 1, resolving no row", ctx do
      rows =
        Enum.map(1..2, fn i ->
          %{
            input: %{
              code: "#{ctx.tag}-#{i}",
              name: "#{ctx.tag} N#{i}",
              native_name: {:resolve, EchoResolver, "#{ctx.tag} A#{i}"}
            }
          }
        end)

      bulk_action =
        Ash.create!(
          BulkAction,
          %{
            user_id: ctx.user.id,
            resource_name: inspect(Region),
            action_name: :create,
            action_type: :create,
            total_rows: 2,
            mode: :per_row,
            chunk_size: 1,
            rows: rows
          },
          action: :create,
          authorize?: false
        )

      assert statuses(bulk_action) == [:pending, :pending]
      phase1 = count_events(bulk_action, [:ash_bulk_durable, :phase1, :start])
      locker = lock_elsewhere(bulk_action.id)

      assert :busy = Worker.run_now(bulk_action.id)

      release(locker)
      assert phase1.() == 0
      assert statuses(bulk_action) == [:pending, :pending]
      assert created(ctx) == []
      assert_untouched(bulk_action)
    end

    test "all or nothing: the same", ctx do
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      locker = lock_elsewhere(bulk_action.id)

      assert :busy = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_untouched(bulk_action)
    end
  end

  # Phase 1 runs outside the lock, but its verdicts are written under it: a
  # run that finds another transaction holding it writes none, and the next
  # run writes it.
  describe "phase 1's verdicts, while another transaction holds the lock" do
    test ":resolver_prepare_error", ctx do
      bulk_action = resolving!(ctx, PrepareRefusingResolver)
      locker = lock_after_start(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:pending, :pending]
      assert_no_verdict(bulk_action)

      assert_verdict_next_run(bulk_action, "resolver_prepare_error")
    end

    test ":staged_file_download_error", ctx do
      bulk_action =
        resolving!(ctx, EchoResolver,
          mode: :all_or_nothing,
          staged_files: %{"a.zip" => "bulk-staging/gone"}
        )

      locker = lock_after_start(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:pending, :pending]
      assert_no_verdict(bulk_action)

      assert_verdict_next_run(bulk_action, "staged_file_download_error")
    end

    test ":atomic_phase1_failed, from a row its caller refused", ctx do
      bulk_action = resolving!(ctx, EchoResolver, mode: :all_or_nothing, refused: true)
      locker = lock_after_start(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:failed, :pending]
      assert_no_verdict(bulk_action)

      assert_verdict_next_run(bulk_action, "atomic_phase1_failed")
    end

    test ":atomic_phase1_failed, from a row that failed to resolve", ctx do
      bulk_action = resolving!(ctx, RefusingResolver, mode: :all_or_nothing)
      locker = lock_after_start(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      # The row's own failure is one of phase 1's single-row writes, which
      # take no lock; the verdict is not.
      assert :failed in statuses(bulk_action)
      assert created(ctx) == []
      assert_no_verdict(bulk_action)

      assert_verdict_next_run(bulk_action, "atomic_phase1_failed")
    end

    test ":unreadable", ctx do
      bulk_action = submit!(ctx, 2)

      # A shared input naming an atom this release doesn't have.
      gone = "gone_atom_#{System.unique_integer([:positive])}"

      Repo.query!("UPDATE bulk_actions SET input = $1 WHERE id = $2", [
        <<131, 119, byte_size(gone)>> <> gone,
        Ecto.UUID.dump!(bulk_action.id)
      ])

      locker = lock_elsewhere(bulk_action.id)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_untouched(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :failed, result: %{"reason" => "unreadable"}} = reload(bulk_action)
    end

    test ":gone", ctx do
      bulk_action = submit!(ctx, 2)

      Repo.query!("UPDATE bulk_actions SET action_name = 'renamed_away' WHERE id = $1", [
        Ecto.UUID.dump!(bulk_action.id)
      ])

      locker = lock_elsewhere(bulk_action.id)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_untouched(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :failed, result: %{"reason" => "gone"}} = reload(bulk_action)
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

      a = start_run(bulk_action)
      assert_receive {:committed, ^a}, 5_000
      b = start_run(bulk_action)
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
      test_pid = self()

      # Inside A's first chunk, under its lock: B runs to its end.
      at_first_chunk(bulk_action, fn ->
        b = start_run(bulk_action)
        assert_receive {:done, ^b, :busy}, 5_000
        send(test_pid, :b_done)
      end)

      assert :ok = Worker.run_now(bulk_action.id)
      assert_received :b_done

      assert statuses(bulk_action) == [:succeeded, :succeeded]
      assert created(ctx) == codes(ctx, 1..2)
      assert %{status: :completed, rows_done: 2} = reload(bulk_action)
    end

    test "a run that finds every row done writes the verdict, once", ctx do
      bulk_action = submit!(ctx, 1)
      assert :ok = Worker.run_now(bulk_action.id)
      finished = reload(bulk_action)
      assert finished.status == :completed

      # As a run that wrote the last row and died before its verdict leaves it.
      id = Ecto.UUID.dump!(bulk_action.id)

      Repo.query!(
        "UPDATE bulk_actions SET status = 'running', result = NULL, finished_at = NULL WHERE id = $1",
        [id]
      )

      assert :ok = Worker.run_now(bulk_action.id)
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

      # Its start finds the bulk action no longer running.
      assert :busy = Worker.run_now(bulk_action.id)
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

      {pid, monitor} =
        spawn_monitor(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          Process.put(:run?, true)
          Worker.run_now(bulk_action.id)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      :telemetry.detach(handler)

      assert created(ctx) == []
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert_no_verdict(bulk_action)

      # Its lock went with its connection.
      assert eventually(fn -> lockable?(bulk_action.id) end)

      assert :ok = Worker.run_now(bulk_action.id)
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

      assert :ok = Worker.run_now(bulk_action.id)

      # The start's, the chunk's, row 1's, and row 2's refused one: row 3 is
      # not tried.
      assert locks.() == 4
      release(locker)
      assert statuses(bulk_action) == [:succeeded, :resolved, :resolved]
      assert created(ctx) == codes(ctx, [1])

      # The next run recovers the rest: row 2 fails alone.
      assert :ok = Worker.run_now(bulk_action.id)
      assert statuses(bulk_action) == [:succeeded, :failed, :succeeded]
      assert created(ctx) == codes(ctx, [1, 3])
      assert %{status: :completed_with_errors, rows_done: 2} = reload(bulk_action)
    end

    test "skips a row another run applied since the chunk read it, and goes on", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 3, chunk_size: 3)
      [_r1, _r2, r3] = rows(bulk_action)
      after_batch(1, fn -> apply_elsewhere(r3) end)

      assert :ok = Worker.run_now(bulk_action.id)

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

      assert :ok = Worker.run_now(bulk_action.id)

      assert [%{status: :succeeded}, %{status: :pending, error: nil}] = rows(bulk_action)
    end

    test "marks a failed row only under the lock", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      locker = lock_after_batch(bulk_action, 3)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      assert [%{status: :succeeded}, %{status: :resolved, error: nil}] = rows(bulk_action)
      assert %{status: :running, result: nil, rows_done: 1} = reload(bulk_action)
    end
  end

  # A failed chunk of 64 rows, its rows halved: rows numbered from 1, the bad
  # ones those whose code another region already took. Each scenario also
  # runs row by row (`halving_min_rows: 0`), on codes of its own, to compare.
  describe "halving a failed chunk" do
    setup do
      on_exit(fn -> Application.delete_env(:ash_bulk_durable, :halving_min_rows) end)
    end

    test "one bad row: the same rows and errors as row by row, in far fewer transactions",
         ctx do
      halved = recovered!(ctx, "h", [37])
      by_row = recovered!(ctx, "r", [37], halving_min_rows: 0)

      assert halved.outcome == by_row.outcome
      assert halved.counts == %{succeeded: 63, failed: 1}
      assert %{recovery: :halving, transactions: 16} = halved.stop
      assert %{recovery: :row_by_row, transactions: 66} = by_row.stop

      # Halved down to single rows: about 2·log2(64).
      tiny = recovered!(ctx, "t", [37], halving_min_rows: 1)
      assert tiny.outcome == by_row.outcome
      assert %{recovery: :halving, transactions: 14} = tiny.stop
    end

    test "several bad rows spread out: the same results, fewer transactions than rows", ctx do
      bad = [8, 24, 40, 56]
      halved = recovered!(ctx, "h", bad)
      by_row = recovered!(ctx, "r", bad, halving_min_rows: 0)

      assert halved.outcome == by_row.outcome
      assert halved.counts == %{succeeded: 60, failed: 4}
      assert %{recovery: :halving, transactions: 51} = halved.stop
      assert %{transactions: 69} = by_row.stop
    end

    # Without the fallback, halving all the way costs 127.
    test "most rows bad: halving falls back, costing close to row by row, not double", ctx do
      bad = Enum.reject(1..64, &(rem(&1, 4) == 0))
      halved = recovered!(ctx, "h", bad)
      by_row = recovered!(ctx, "r", bad, halving_min_rows: 0)

      assert halved.outcome == by_row.outcome
      assert halved.counts == %{succeeded: 16, failed: 48}
      assert %{recovery: :row_by_row, transactions: 119} = halved.stop
      assert %{transactions: 113} = by_row.stop
    end

    test "halving_min_rows: 0 runs every row alone, as before", ctx do
      Application.put_env(:ash_bulk_durable, :halving_min_rows, 0)
      bulk_action = submit_set!(ctx, "z", 64, [37])
      locks = count_locks()

      assert :ok = Worker.run_now(bulk_action.id)

      # The start's, the chunk's, a run alone for each row, row 37's mark, and
      # the verdict's chunk.
      assert locks.() == 1 + 1 + 64 + 1 + 1
    end

    test "stops at a lock another transaction holds mid-recovery, writing nothing more", ctx do
      bulk_action = submit_set!(ctx, "l", 64, [37])

      # The `:run` batches end in order: the chunk's, then rows 1-32's, which
      # commit. Rows 33-64 then find the lock held.
      locker = lock_after_batch(bulk_action, 2)
      locks = count_locks()

      assert :ok = Worker.run_now(bulk_action.id)

      # The start's, the chunk's, rows 1-32's, and rows 33-64's refused one.
      assert locks.() == 4
      release(locker)

      assert statuses(bulk_action) ==
               List.duplicate(:succeeded, 32) ++ List.duplicate(:resolved, 32)

      assert length(created_with(ctx, "l")) == 32

      assert :ok = Worker.run_now(bulk_action.id)
      assert length(created_with(ctx, "l")) == 63
      assert %{status: :completed_with_errors, rows_done: 63} = reload(bulk_action)
    end

    # Without the read under the lock, rows 33-64 would run row 40 again: its
    # flip is refused, and the run stops with `{:stopped, :row_moved_on}`.
    test "drops a row another run applied mid-recovery from its set, and runs it no more",
         ctx do
      bulk_action = submit_set!(ctx, "a", 64, [37])
      row40 = Enum.at(rows(bulk_action), 39)

      # After rows 1-32 commit, and before rows 33-64 run, another run applies
      # row 40.
      after_batch(2, fn -> apply_elsewhere(row40) end)
      stops = chunk_stops(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      # Rows 33-64 run as 31 rows. Run with row 40 in them, each set holding
      # it would fail on its refused flip, and halve on down to it alone.
      assert [{%{transactions: 15, rows_succeeded: 62, rows_failed: 1}, _}] = stops.()

      assert %{status: :succeeded, record_id: "other"} = Enum.at(rows(bulk_action), 39)
      refute "#{ctx.tag}-a40" in created_with(ctx, "a")
      assert length(created_with(ctx, "a")) == 62
      assert %{status: :completed_with_errors, rows_done: 62} = reload(bulk_action)
    end
  end

  describe "all or nothing, rolled back" do
    test "writes its verdict under the lock: not while another transaction holds it", ctx do
      taken!(ctx, 2)
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      locker = lock_after_batch(bulk_action, 1)

      assert :ok = Worker.run_now(bulk_action.id)

      release(locker)
      assert statuses(bulk_action) == [:resolved, :resolved]
      assert created(ctx) == []
      assert_no_verdict(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)
      assert created(ctx) == []

      assert %{status: :failed, result: %{"reason" => "atomic_chunk_rolled_back"}} =
               reload(bulk_action)
    end
  end

  # Part 1's compare-and-set still catches a write that slips past the lock,
  # here one from a connection that never takes it.
  describe "a row moved on under another run" do
    test "phase 2, per row: the chunk rolls back with no recovery, and the run stops",
         ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      [_r1, r2] = rows(bulk_action)
      at_first_chunk(bulk_action, fn -> apply_elsewhere(r2) end)
      spans = count_chunk_events(bulk_action)

      assert {:stopped, :row_moved_on} = Worker.run_now(bulk_action.id)
      assert spans.() == %{start: 1, stop: 0, exception: 1}

      # Row 1's target write and flip shared the refused flip's transaction.
      assert created(ctx) == []
      assert [%{status: :resolved}, %{status: :succeeded, record_id: "other"}] = rows(bulk_action)
      assert_no_verdict(bulk_action)
    end

    test "phase 2, all or nothing: the transaction rolls back, no rollback verdict, and the run stops",
         ctx do
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      [_r1, r2] = rows(bulk_action)
      at_first_chunk(bulk_action, fn -> apply_elsewhere(r2) end)
      spans = count_chunk_events(bulk_action)

      assert {:stopped, :row_moved_on} = Worker.run_now(bulk_action.id)
      assert spans.() == %{start: 1, stop: 0, exception: 1}
      assert created(ctx) == []
      assert [%{status: :resolved}, %{status: :succeeded, record_id: "other"}] = rows(bulk_action)
      assert_no_verdict(bulk_action)
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

      assert :ok = Worker.run_now(bulk_action.id)
      assert spans.() == %{start: 1, stop: 1, exception: 0}

      # Row 1 committed alone before; row 2 keeps the other run's write.
      assert [%{status: :succeeded}, %{status: :succeeded, record_id: "other", error: nil}] =
               rows(bulk_action)

      assert created(ctx) == codes(ctx, [1])
      assert %{status: :completed_with_errors, rows_done: 1} = reload(bulk_action)
    end
  end

  describe "a run that outlives a retry" do
    test "phase 2: stops at its next lock, writing no row and no verdict; the retry's pass runs with its input",
         ctx do
      [old, new] = Enum.map(1..2, &region!(ctx, "R#{&1}"))
      [_b1, _b2, b3] = branches = Enum.map(1..3, &branch!(ctx, &1))

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(branches, :update, %{region_id: old.id},
          scope: ctx.scope,
          chunk_size: 1
        )

      a = start_held_run(bulk_action)
      assert_receive {:committed, ^a}, 5_000

      # Run B, while A waits between chunks: row 3's branch is gone, so B
      # ends `:completed_with_errors`. Its owner brings the branch back and
      # retries with a new shared input.
      gone = take_away!(b3)
      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed_with_errors, pass: 0} = reload(bulk_action)
      bring_back!(gone)

      assert {:ok, %{status: :running, pass: 1}} =
               AshBulkDurable.retry(bulk_action, scope: ctx.scope, input: %{region_id: new.id})

      send(a, :go)
      assert_receive {:done, ^a, :ok}, 5_000

      # A applied nothing of the new pass, and wrote no verdict.
      assert region_of(b3) == nil
      assert statuses(bulk_action) == [:succeeded, :succeeded, :resolved]
      assert %{status: :running, result: nil, finished_at: nil} = reload(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)
      assert region_of(b3) == new.id
      assert %{status: :completed, rows_done: 3} = reload(bulk_action)
    end

    test "phase 1: writes no verdict of its own pass into the retry's", ctx do
      bulk_action = submit_unpreparable!(ctx)

      a = start_held_run(bulk_action)
      assert_receive {:preparing, ^a}, 5_000

      # Run B fails the bulk action as A is about to, and its owner retries it.
      assert :ok = Worker.run_now(bulk_action.id)

      assert %{status: :failed, result: %{"reason" => "resolver_prepare_error"}} =
               reload(bulk_action)

      assert {:ok, %{status: :running, pass: 1}} =
               AshBulkDurable.retry(bulk_action, scope: ctx.scope)

      send(a, :go)
      assert_receive {:done, ^a, :ok}, 5_000

      assert %{status: :running, result: nil, finished_at: nil, pass: 1} = reload(bulk_action)
    end
  end

  # Phase 1's row writes take no lock: each carries the run's pass, and
  # matches its row only while the bulk action is still on it.
  describe "a run in phase 1 that outlives a retry" do
    test "has its :resolve of the reopened row refused, and stops; the retry's pass resolves it with its input",
         ctx do
      taken!(ctx, 1)
      bulk_action = shared_resolving!(ctx, "old")

      a = start_held_run(bulk_action)
      assert_receive {:preparing, ^a}, 5_000

      # Run B, while A waits with the row read: row 1's code is taken, so B
      # ends `:completed_with_errors`. Its owner frees the code and retries
      # with a new shared input, which reopens the row to `:pending`.
      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed_with_errors, pass: 0} = reload(bulk_action)
      free!(ctx, 1)
      assert {:ok, %{status: :running, pass: 1}} = retry_with!(ctx, bulk_action, "new")
      assert [%{status: :pending, pass: 1, resolved_data: reopened}] = rows(bulk_action)

      send(a, :go)
      assert_receive {:done, ^a, {:stopped, :row_moved_on}}, 5_000

      # A wrote nothing of its old input, and no verdict.
      assert [%{status: :pending, pass: 1, resolved_data: ^reopened}] = rows(bulk_action)
      assert %{status: :running, result: nil, finished_at: nil} = reload(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed, rows_done: 1} = reload(bulk_action)
      assert native_names(ctx) == ["#{ctx.tag} new"]
    end

    test "has its :mark_failed of the reopened row refused, and stops; the retry's pass resolves it",
         ctx do
      bulk_action = shared_resolving!(ctx, "old bad")

      a = start_held_run(bulk_action)
      assert_receive {:preparing, ^a}, 5_000

      # Run B fails the row in phase 1, and its owner retries with an input
      # that resolves.
      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed_with_errors, pass: 0} = reload(bulk_action)
      assert {:ok, %{status: :running, pass: 1}} = retry_with!(ctx, bulk_action, "new")
      assert [%{status: :pending, error: nil}] = rows(bulk_action)

      send(a, :go)
      assert_receive {:done, ^a, {:stopped, :row_moved_on}}, 5_000

      # A's failure of the old input is not on the row.
      assert [%{status: :pending, error: nil}] = rows(bulk_action)
      assert %{status: :running, result: nil, finished_at: nil} = reload(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed, rows_done: 1} = reload(bulk_action)
      assert native_names(ctx) == ["#{ctx.tag} new"]
    end

    # The retry's transaction holds the row it reopened when A's `:resolve`
    # starts, so A's UPDATE waits on it, and rechecks only the row's new
    # version once the retry commits.
    test "has its :resolve that waited on the row while the retry held it refused, and stops",
         ctx do
      bulk_action = shared_resolving!(ctx, "old")

      a = start_held_run(bulk_action)
      assert_receive {:preparing, ^a}, 5_000

      # As another run failed it outright, its row left `:pending`.
      Repo.query!(
        "UPDATE bulk_actions SET status = 'failed', finished_at = now() WHERE id = $1",
        [Ecto.UUID.dump!(bulk_action.id)]
      )

      retry = start_held_retry(ctx, bulk_action, "new")
      assert_receive {:reopened, ^retry}, 5_000

      send(a, :go)
      assert eventually(&resolve_waiting_on_row?/0)

      send(retry, :go)
      assert_receive {:retried, ^retry, {:ok, %{pass: 1}}}, 5_000
      assert_receive {:done, ^a, {:stopped, :row_moved_on}}, 5_000

      # The row keeps the retry's input and pass, nothing resolved of A's.
      assert [%{status: :pending, pass: 1, resolved_data: resolved}] = rows(bulk_action)
      refute Map.has_key?(resolved, "native_name")
      assert %{status: :running, result: nil, pass: 1} = reload(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed, rows_done: 1} = reload(bulk_action)
      assert native_names(ctx) == ["#{ctx.tag} new"]
    end

    test "has its :mark_failed of a row whose staged files it lost refused, and stops", ctx do
      bulk_action = resolving!(ctx, EchoResolver, staged_files: %{"a.zip" => "bulk-staging/gone"})
      hold_after_download(bulk_action)

      a = start_held_run(bulk_action)
      assert_receive {:downloaded, ^a}, 5_000

      # Run B fails both rows for their staged files, and its owner retries.
      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed_with_errors, pass: 0} = reload(bulk_action)

      assert {:ok, %{status: :running, pass: 1}} =
               AshBulkDurable.retry(bulk_action, scope: ctx.scope)

      assert [%{status: :pending, error: nil}, %{status: :pending, error: nil}] =
               rows(bulk_action)

      send(a, :go)
      assert_receive {:done, ^a, {:stopped, :row_moved_on}}, 5_000

      # A's failure of its pass is not on the reopened rows, and it wrote no verdict.
      assert [%{status: :pending, error: nil}, %{status: :pending, error: nil}] =
               rows(bulk_action)

      assert %{status: :running, result: nil, finished_at: nil, pass: 1} = reload(bulk_action)
    end
  end

  describe "the verdict" do
    test "waits for a row another run put back to :pending between chunks", ctx do
      bulk_action = submit!(ctx, 3)

      a = start_held_run(bulk_action)
      assert_receive {:committed, ^a}, 5_000

      # As another run's `forget_resolutions` leaves a row whose resolutions it lost.
      [_r1, _r2, r3] = rows(bulk_action)
      reopen_elsewhere(r3)

      send(a, :go)
      assert_receive {:committed, ^a}, 5_000
      send(a, :go)
      assert_receive {:done, ^a, :ok}, 5_000

      assert statuses(bulk_action) == [:succeeded, :succeeded, :pending]

      assert %{status: :running, result: nil, finished_at: nil, rows_done: 2} =
               reload(bulk_action)

      # The next run resolves and applies it, then writes the verdict.
      assert :ok = Worker.run_now(bulk_action.id)
      assert statuses(bulk_action) == List.duplicate(:succeeded, 3)
      assert created(ctx) == codes(ctx, 1..3)
      assert %{status: :completed, rows_done: 3} = reload(bulk_action)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # How many times `event` fired for the bulk action.
  defp count_events(bulk_action, event) do
    counter = :counters.new(1, [])
    handler = "count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      event,
      fn _event, _measurements, %{bulk_action_id: id}, _config ->
        if id == bulk_action.id, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fn -> :counters.get(counter, 1) end
  end

  # Two rows whose native names `resolver` resolves in phase 1; with
  # `refused: true`, the first was refused by its caller before it was stored.
  # Takes `:mode` and `:staged_files` too.
  defp resolving!(ctx, resolver, opts \\ []) do
    rows =
      Enum.map(1..2, fn i ->
        row = %{
          input: %{
            code: "#{ctx.tag}-#{i}",
            name: "#{ctx.tag} N#{i}",
            native_name: {:resolve, resolver, "#{ctx.tag} A#{i}"}
          }
        }

        if i == 1 and opts[:refused], do: Map.put(row, :error, "unreadable cell"), else: row
      end)

    Ash.create!(
      BulkAction,
      %{
        user_id: ctx.user.id,
        resource_name: inspect(Region),
        action_name: :create,
        action_type: :create,
        total_rows: 2,
        mode: Keyword.get(opts, :mode, :per_row),
        chunk_size: 1,
        staged_files: Keyword.get(opts, :staged_files, %{}),
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  # From the moment the run's start transaction commits, another connection
  # holds the bulk action's lock, until told.
  defp lock_after_start(bulk_action) do
    test_pid = self()
    handler = "lock-after-start-#{bulk_action.id}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :test, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == test_pid and query == "commit" do
          :telemetry.detach(handler)
          send(test_pid, {:locker, lock_elsewhere(bulk_action.id)})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    fn ->
      assert_received {:locker, locker}
      locker
    end
  end

  # The verdict the held lock kept back, written by the next run.
  defp assert_verdict_next_run(bulk_action, reason) do
    assert :ok = Worker.run_now(bulk_action.id)
    assert %{status: :failed, result: %{"reason" => ^reason}} = reload(bulk_action)
  end

  # A run of the bulk action in a process of its own that, after each of its
  # chunks commits and in phase 1 as `UnpreparableResolver` readies, says so
  # and waits for `:go`.
  defp start_held_run(bulk_action) do
    test_pid = self()
    handler = "held-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :chunk, :stop],
      fn _event, _measurements, %{bulk_action_id: id}, _config ->
        if id == bulk_action.id and Process.get(:hold) do
          send(test_pid, {:committed, self()})
          receive do: (:go -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    spawn_link(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      Process.put(:hold, test_pid)
      send(test_pid, {:done, self(), Worker.run_now(bulk_action.id)})
    end)
  end

  # A retry in a process of its own, with a new shared input, that says so
  # once it has reopened the rows and moved the bulk action on, and waits for
  # `:go` before its transaction commits.
  defp start_held_retry(ctx, bulk_action, value) do
    test_pid = self()
    handler = "held-retry-#{bulk_action.id}"

    pid =
      spawn_link(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        receive do: (:start -> :ok)
        send(test_pid, {:retried, self(), retry_with!(ctx, bulk_action, value)})
      end)

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :test, :repo, :query],
      fn _event, _measurements, %{source: source, query: query}, _config ->
        if self() == pid and source == "bulk_actions" and String.starts_with?(query, "UPDATE") do
          :telemetry.detach(handler)
          send(test_pid, {:reopened, pid})
          receive do: (:go -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(pid, :start)
    pid
  end

  # A `:resolve` of a row waits on another transaction's lock.
  defp resolve_waiting_on_row? do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' " <>
          "AND query LIKE 'UPDATE \"bulk_action_rows\"%'"
      )

    count > 0
  end

  # A run told to hold (see `start_held_run/1`) says so once its staged-file
  # download has failed, and waits for `:go` before failing the rows that
  # needed the files.
  defp hold_after_download(bulk_action) do
    handler = "held-download-#{bulk_action.id}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :staged_files_download, :stop],
      fn _event, _measurements, %{bulk_action_id: id}, _config ->
        with true <- id == bulk_action.id, pid when is_pid(pid) <- Process.get(:hold) do
          send(pid, {:downloaded, self()})
          receive do: (:go -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # One row running with the shared input, whose native name resolves,
  # through `HeldResolver`, to the tag and `value`.
  defp shared_resolving!(ctx, value) do
    {:ok, bulk_action} =
      AshBulkDurable.Core.create(Region, :create, [%{}],
        scope: ctx.scope,
        chunk_size: 1,
        input: shared_input(ctx, value)
      )

    bulk_action
  end

  defp retry_with!(ctx, bulk_action, value),
    do: AshBulkDurable.retry(bulk_action, scope: ctx.scope, input: shared_input(ctx, value))

  defp shared_input(ctx, value) do
    %{
      code: "#{ctx.tag}-1",
      name: "#{ctx.tag} N1",
      native_name: {:resolve, HeldResolver, "#{ctx.tag} #{value}"}
    }
  end

  defp free!(ctx, i), do: Repo.query!("DELETE FROM regions WHERE code = $1", ["#{ctx.tag}-#{i}"])

  defp native_names(ctx) do
    %{rows: rows} =
      Repo.query!(
        "SELECT native_name FROM regions WHERE code LIKE $1 || '-%' AND name NOT LIKE '%X%'",
        [ctx.tag]
      )

    List.flatten(rows)
  end

  defp submit_unpreparable!(ctx) do
    Ash.create!(
      BulkAction,
      %{
        user_id: ctx.user.id,
        resource_name: inspect(Region),
        action_name: :create,
        action_type: :create,
        total_rows: 1,
        mode: :per_row,
        chunk_size: 1,
        rows: [
          %{
            input: %{
              code: "#{ctx.tag}-1",
              name: "#{ctx.tag} N1",
              native_name: {:resolve, UnpreparableResolver, "a"}
            }
          }
        ]
      },
      action: :create,
      authorize?: false
    )
  end

  defp region!(ctx, suffix) do
    Ash.create!(
      Region,
      %{code: "#{ctx.tag}-#{suffix}", name: "#{ctx.tag} X#{suffix}", native_name: "X#{suffix}"},
      authorize?: false
    )
  end

  defp branch!(ctx, i), do: Ash.create!(Branch, %{name: "#{ctx.tag} B#{i}"}, authorize?: false)

  defp region_of(branch) do
    %{rows: [[region_id]]} =
      Repo.query!("SELECT region_id FROM branches WHERE id = $1", [Ecto.UUID.dump!(branch.id)])

    region_id && Ecto.UUID.load!(region_id)
  end

  # Deletes `branch`, and returns what brings it back with the same id.
  defp take_away!(branch) do
    Repo.query!("DELETE FROM branches WHERE id = $1", [Ecto.UUID.dump!(branch.id)])
    branch
  end

  defp bring_back!(branch) do
    Repo.query!("INSERT INTO branches (id, name) VALUES ($1, $2)", [
      Ecto.UUID.dump!(branch.id),
      branch.name
    ])
  end

  # A run of the bulk action in a process of its own, as another node's would be.
  # ── Halving ────────────────────────────────────────────────────────────

  # A per-row bulk action of `count` rows in one chunk, coded
  # "<tag>-<prefix><i>", whose `bad` rows find their code already taken.
  defp submit_set!(ctx, prefix, count, bad) do
    # An owner of its own, since one may have one unresolved bulk action.
    scope = Scope.new(actor: create_user!(prefix <> ctx.tag))

    Enum.each(bad, fn i ->
      Ash.create!(
        Region,
        %{
          code: "#{ctx.tag}-#{prefix}#{i}",
          name: "#{ctx.tag} #{prefix}X#{i}",
          native_name: "#{prefix}X#{i}"
        },
        authorize?: false
      )
    end)

    inputs =
      Enum.map(1..count, fn i ->
        %{
          code: "#{ctx.tag}-#{prefix}#{i}",
          name: "#{ctx.tag} #{prefix}N#{i}",
          native_name: "#{prefix}A#{i}"
        }
      end)

    {:ok, bulk_action} =
      AshBulkDurable.bulk_create(inputs, Region, :create, scope: scope, chunk_size: count)

    bulk_action
  end

  # Runs a 64-row chunk with `bad` rows, with `config` for the run, and gives
  # its rows' statuses and errors (codes made alike), the counts, and the
  # chunk's `:stop` measurements and metadata.
  defp recovered!(ctx, prefix, bad, config \\ []) do
    Application.delete_env(:ash_bulk_durable, :halving_min_rows)
    Enum.each(config, fn {key, value} -> Application.put_env(:ash_bulk_durable, key, value) end)
    bulk_action = submit_set!(ctx, prefix, 64, bad)
    stops = chunk_stops(bulk_action)

    assert :ok = Worker.run_now(bulk_action.id)
    Application.delete_env(:ash_bulk_durable, :halving_min_rows)

    assert [{measurements, metadata}] = stops.()
    assert %{status: :completed_with_errors} = reload(bulk_action)

    rows = rows(bulk_action)
    assert Enum.all?(rows, &(&1.status != :failed or &1.error not in [nil, []]))
    alike = &String.replace(&1, "#{ctx.tag}-#{prefix}", "CODE-")

    %{
      outcome: Enum.map(rows, &{&1.row_index, &1.status, alike.(inspect(&1.error))}),
      counts: %{
        succeeded: Enum.count(rows, &(&1.status == :succeeded)),
        failed: Enum.count(rows, &(&1.status == :failed))
      },
      stop: Map.merge(measurements, Map.take(metadata, [:recovery, :outcome]))
    }
  end

  # The bulk action's chunk `:stop` events so far, oldest first.
  defp chunk_stops(bulk_action) do
    test_pid = self()
    handler = "chunk-stops-#{bulk_action.id}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :chunk, :stop],
      fn _event, measurements, %{bulk_action_id: id} = metadata, _config ->
        if id == bulk_action.id, do: send(test_pid, {:chunk_stop, id, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    fn ->
      :telemetry.detach(handler)
      collect_stops(bulk_action.id, [])
    end
  end

  defp collect_stops(id, acc) do
    receive do
      {:chunk_stop, ^id, measurements, metadata} ->
        collect_stops(id, [{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp created_with(ctx, prefix) do
    %{rows: rows} =
      Repo.query!("SELECT code FROM regions WHERE code LIKE $1 AND name NOT LIKE '%X%'", [
        "#{ctx.tag}-#{prefix}%"
      ])

    List.flatten(rows)
  end

  defp start_run(bulk_action) do
    test_pid = self()

    spawn_link(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      send(test_pid, {:done, self(), Worker.run_now(bulk_action.id)})
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

  # The bulk action locks the test process (the run, under `Worker.run_now/1`)
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

    Repo.query!("DELETE FROM bulk_actions WHERE user_id IN (#{users})", [email])
    Repo.query!("DELETE FROM branches WHERE name LIKE $1 || ' %'", [tag])
    Repo.query!("DELETE FROM regions WHERE code LIKE $1 || '-%'", [tag])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [email])
  end
end
