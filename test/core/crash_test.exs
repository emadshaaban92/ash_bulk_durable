defmodule AshBulkDurable.Core.CrashTest do
  @moduledoc """
  Runs that die without returning: counting the starts that made no
  progress, running rows alone once a bulk action stalls, and failing the
  row that keeps killing its run. A killed run's transaction rolls back on
  its own connection while what it committed before stays, so this test
  runs outside the sandbox, each run in a process of its own, and deletes
  what it wrote.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  defmodule KillingResolver do
    @moduledoc """
    Kills the run resolving it, as running out of memory or losing the node
    would. Killing only its own task would fail just its row.
    """
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_value, nil, _context) do
      [run | _] = Process.get(:"$callers")
      Process.exit(run, :kill)
      Process.sleep(:infinity)
    end

    @impl true
    def finish(nil), do: :ok
  end

  defmodule ResettingResolver do
    @moduledoc """
    Resolves while another writer takes every bump back from the pending rows
    of the bulk actions of the user it is given.
    """
    @behaviour AshBulkDurable.Core.Resolver

    alias AshBulkDurable.Test.Repo

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(user_id, nil, _context) do
      Repo.query!(
        "UPDATE bulk_action_rows SET attempts = 0 WHERE status = 'pending' AND bulk_action_id IN " <>
          "(SELECT id FROM bulk_actions WHERE user_id = $1)",
        [Ecto.UUID.dump!(user_id)]
      )

      {:ok, "resolved #{user_id}"}
    end

    @impl true
    def finish(nil), do: :ok
  end

  defmodule RaisingOwner do
    @moduledoc "The test owner, but its scopes can't be rebuilt: the user is gone."
    @behaviour AshBulkDurable.Core.Owner

    @impl true
    def worker_key(scope), do: AshBulkDurable.Test.Owner.worker_key(scope)

    @impl true
    def scope_from_worker_key(_key, _tenant), do: raise("the user is gone")
  end

  defmodule KillingOwner do
    @moduledoc "The test owner, but rebuilding a scope kills the run."
    @behaviour AshBulkDurable.Core.Owner

    @impl true
    def worker_key(scope), do: AshBulkDurable.Test.Owner.worker_key(scope)

    @impl true
    def scope_from_worker_key(_key, _tenant), do: Process.exit(self(), :kill)
  end

  alias AshBulkDurable.Core.{CrashedRowError, Retry, Worker}
  alias AshBulkDurable.Test.{BulkAction, Region, Repo, Row, Scope, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    tag = "crash#{System.unique_integer([:positive])}"

    user = create_user!(tag)
    on_exit(fn -> cleanup(tag) end)
    %{user: user, scope: Scope.new(actor: user), tag: tag}
  end

  describe "counting stalled starts" do
    test "the first start stores the score, counts none, and clears isolating_row_id", ctx do
      bulk_action = submit!(ctx, 2)
      [r1, _r2] = rows(bulk_action)
      # Left by a run that died for real while running row 1 alone.
      set!(bulk_action, "isolating_row_id = $2", [Ecto.UUID.dump!(r1.id)])

      assert %{progress_at_start: nil, stalled_starts: 0} = reload(bulk_action)
      assert :ok = Worker.run_now(bulk_action.id)

      # Both rows `:resolved` when it started: moved on, not finished.
      assert %{status: :completed, progress_at_start: 2, stalled_starts: 0, isolating_row_id: nil} =
               reload(bulk_action)
    end

    test "a start without progress adds one", ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      kill_on_row(ctx, 2)

      assert :killed = attempt(bulk_action)
      assert %{progress_at_start: 2, stalled_starts: 0} = reload(bulk_action)

      assert :killed = attempt(bulk_action)
      assert %{progress_at_start: 2, stalled_starts: 1} = reload(bulk_action)
    end

    test "a start after progress, phase 1's included, sets it back to 0", ctx do
      bulk_action = submit_resolving!(ctx, [{EchoResolver, "a"}, {EchoResolver, "b"}])
      [r1, _r2] = rows(bulk_action)

      # Two stalled starts so far, the last scoring both rows `:pending`.
      set!(bulk_action, "progress_at_start = 0, stalled_starts = 2")
      # Since then, a run resolved one row.
      set_row!(r1, ~s(status = 'resolved', resolved_data = '{"native_name": "a"}'))

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed, progress_at_start: 1, stalled_starts: 0} = reload(bulk_action)
    end

    test "a start that finds the lock held writes nothing", ctx do
      bulk_action = submit!(ctx, 2)
      set!(bulk_action, "status = 'running', progress_at_start = 2, stalled_starts = 1")
      locker = lock_elsewhere(bulk_action.id)

      assert :busy = Worker.run_now(bulk_action.id)

      release(locker)
      assert %{progress_at_start: 2, stalled_starts: 1} = reload(bulk_action)
    end
  end

  describe "a row that kills its run" do
    test "per row: after three stalled starts, every row runs alone, and that row fails alone",
         ctx do
      bulk_action = submit!(ctx, 5, chunk_size: 5)
      kill_on_row(ctx, 3)
      isolations = collect([:ash_bulk_durable, :isolation, :start], bulk_action)
      crashed = collect([:ash_bulk_durable, :row, :crashed], bulk_action)

      # Starts 1 to 3 die in the one chunk, rolling it back, so nothing moves.
      for stalled <- 0..2 do
        assert :killed = attempt(bulk_action)
        assert %{stalled_starts: ^stalled} = reload(bulk_action)
        assert statuses(bulk_action) == List.duplicate(:resolved, 5)
        assert attempts(bulk_action) == [0, 0, 0, 0, 0]
      end

      assert isolations.() == []

      # Start 4 stalled out: rows run alone, each bumped before it runs, and
      # row 3's bump outlives its run.
      log = capture_log(fn -> assert :killed = attempt(bulk_action) end)
      assert log =~ "made no progress in its last 3 starts; running its rows one at a time"
      assert [{%{stalled_starts: 3}, %{mode: :per_row}}] = isolations.()
      assert %{stalled_starts: 3, isolating_row_id: isolating} = reload(bulk_action)
      assert statuses(bulk_action) == [:succeeded, :succeeded, :resolved, :resolved, :resolved]
      assert attempts(bulk_action) == [1, 1, 1, 0, 0]
      assert isolating == Enum.at(rows(bulk_action), 2).id

      # Start 5 made progress, so it runs chunks again, but row 3 first,
      # alone: it dies on it before the chunk of rows 4 and 5.
      assert :killed = attempt(bulk_action)
      assert %{stalled_starts: 0} = reload(bulk_action)
      assert statuses(bulk_action) == [:succeeded, :succeeded, :resolved, :resolved, :resolved]
      assert attempts(bulk_action) == [1, 1, 2, 0, 0]

      # Start 6 fails row 3 without running it, and runs the rest.
      log = capture_log(fn -> assert {:ran, :ok} = attempt(bulk_action) end)
      [_r1, _r2, r3, _r4, _r5] = rows(bulk_action)
      assert log =~ "row 2 (#{r3.id}) stopped the worker 2 times"
      assert [{%{attempts: 2}, %{row_id: row_id, row_index: 2}}] = crashed.()
      assert row_id == r3.id

      assert statuses(bulk_action) == [:succeeded, :succeeded, :failed, :succeeded, :succeeded]
      assert %{error: [%{error: %CrashedRowError{attempts: 2}} = stored]} = r3
      assert stored.message == "this row stopped the worker 2 times, so it was not run again"
      assert created(ctx) == codes(ctx, [1, 2, 4, 5])
      assert %{status: :completed_with_errors, rows_done: 4} = reload(bulk_action)

      # Five restarts after the first start.
      assert starts(bulk_action) == 6
    end

    test "phase 1: a resolver that kills its run fails its row the same way", ctx do
      bulk_action =
        submit_resolving!(ctx, [
          {EchoResolver, "a"},
          {KillingResolver, "b"},
          {EchoResolver, "c"}
        ])

      # Row 1 resolves, then 3 stalled starts, and 2 that die on row 2 alone:
      # the 7th fails it, and runs the rest.
      capture_log(fn -> assert run_until_finished(bulk_action) == 7 end)

      assert [
               %{status: :succeeded},
               %{status: :failed, attempts: 2, error: [%{error: %CrashedRowError{attempts: 2}}]},
               %{status: :succeeded}
             ] = rows(bulk_action)

      assert created(ctx) == codes(ctx, [1, 3])
      assert %{status: :completed_with_errors, rows_done: 2} = reload(bulk_action)
    end

    test "all or nothing: after three stalled starts it fails as crashed, its rows untouched",
         ctx do
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      kill_on_row(ctx, 2)

      for _start <- 1..3, do: assert(:killed = attempt(bulk_action))
      assert %{status: :running, stalled_starts: 2} = reload(bulk_action)

      log = capture_log(fn -> assert {:ran, :ok} = attempt(bulk_action) end)
      assert log =~ "failing it, as all or nothing has no row to run alone"

      assert %{status: :failed, result: %{"reason" => "crashed"}, stalled_starts: 3} =
               reload(bulk_action)

      assert statuses(bulk_action) == [:resolved, :resolved]
      assert attempts(bulk_action) == [0, 0]
      assert created(ctx) == []
    end
  end

  describe "suspect rows" do
    test "in a normal pass, a suspect runs alone before the chunks",
         ctx do
      bulk_action = submit!(ctx, 3, chunk_size: 3)
      [_r1, _r2, r3] = rows(bulk_action)
      # A run died while running row 3 alone.
      set_row!(r3, "attempts = 1")
      inserts = collect_inserts(ctx)

      assert :ok = Worker.run_now(bulk_action.id)

      assert inserts.() == Enum.map([3, 1, 2], &codes(ctx, [&1]))
      assert attempts(bulk_action) == [0, 0, 2]
      assert statuses(bulk_action) == [:succeeded, :succeeded, :succeeded]

      # Its run alone recorded how it went, and stopped naming it.
      assert %{status: :completed, stalled_starts: 0, isolating_row_id: nil} =
               reload(bulk_action)
    end
  end

  describe "a suspect resolved alone" do
    test "gives back only its own run's bump, so earlier deaths still count", ctx do
      bulk_action = submit_resolving!(ctx, [{EchoResolver, "a"}])
      [r1] = rows(bulk_action)
      # A run died on it in phase 2, and its resolution was lost since.
      set_row!(r1, "attempts = 1")
      kill_on_row(ctx, 1)

      # Resolved alone (bumped to 2, given back to 1), then run alone in
      # phase 2 (bumped to 2): it dies.
      assert :killed = attempt(bulk_action)
      assert [%{status: :resolved, attempts: 2}] = rows(bulk_action)

      # Two deaths in phase 2: it fails, not run again.
      capture_log(fn -> assert {:ran, :ok} = attempt(bulk_action) end)

      assert [%{status: :failed, attempts: 2, error: [%{error: %CrashedRowError{}}]}] =
               rows(bulk_action)

      assert %{status: :completed_with_errors} = reload(bulk_action)
    end
  end

  describe "a bulk action whose action is gone" do
    # A deploy renamed or removed what it runs, or this node is still on the
    # release before the one that added it: each start counts a setup
    # failure, running nothing, and the third fails it as gone.
    for {mode, column, name} <- [
          {:per_row, "action_name", "renamed_away"},
          {:all_or_nothing, "action_name", "renamed_away"},
          {:per_row, "resource_name", "AshBulkDurable.Test.NoLongerHere"}
        ] do
      test "#{mode}, its #{column} gone: counted, and failed on the third start, nothing run",
           ctx do
        bulk_action = submit!(ctx, 2, mode: unquote(mode))
        set!(bulk_action, "#{unquote(column)} = $2", [unquote(name)])

        capture_log(fn ->
          for failures <- 1..2 do
            assert :ok = Worker.run_now(bulk_action.id)

            assert %{status: :running, setup_failures: ^failures, result: nil} =
                     reload(bulk_action)
          end

          assert :ok = Worker.run_now(bulk_action.id)
        end)

        assert %{status: :failed, result: %{"reason" => "gone"}, setup_failures: 3} =
                 failed = reload(bulk_action)

        assert statuses(bulk_action) == [:resolved, :resolved]
        assert created(ctx) == []

        # Nothing a retry can run either.
        assert {:error, :gone} = AshBulkDurable.retry(failed, scope: ctx.scope)
        assert reload(bulk_action).status == :failed

        # The verdict frees the owner to submit again.
        assert %{status: :queued} = submit!(ctx, 1)
      end
    end

    test "a rolling deploy: an old node's start is counted and spaced, an upgraded one runs it",
         ctx do
      bulk_action = submit!(ctx, 2)
      set!(bulk_action, "action_name = 'added_by_the_next_release'")

      # The old node's start runs nothing, and leaves its hint to go stale,
      # so a poller starts it again only a `:stale_after` later.
      capture_log(fn -> assert :ok = Worker.run_now(bulk_action.id) end)
      assert %{status: :running, setup_failures: 1, alive_at: alive_at} = reload(bulk_action)
      assert alive_at
      assert :busy = Worker.run(bulk_action.id, if_stale_after: :timer.minutes(1))
      assert statuses(bulk_action) == [:resolved, :resolved]

      # An upgraded node has the action.
      set!(bulk_action, "action_name = 'create'")
      assert :ok = Worker.run_now(bulk_action.id)

      assert %{status: :completed} = reload(bulk_action)
      assert statuses(bulk_action) == [:succeeded, :succeeded]
      assert length(created(ctx)) == 2
    end
  end

  describe "a run that raises before its first row" do
    # The owner's user deleted, a storage that raises: every start raises
    # again, moving no row, so stalled starts alone would never end it.
    for mode <- [:per_row, :all_or_nothing] do
      test "#{mode}: counted, and failed on the third, the owner free again", ctx do
        bulk_action = submit!(ctx, 2, mode: unquote(mode))
        owner(RaisingOwner)

        capture_log(fn ->
          for failures <- 1..2 do
            assert {%RuntimeError{message: "the user is gone"}, _} = attempt(bulk_action)

            assert %{status: :running, setup_failures: ^failures, result: nil} =
                     reload(bulk_action)
          end

          assert {%RuntimeError{}, _} = attempt(bulk_action)
        end)

        assert %{
                 status: :failed,
                 setup_failures: 3,
                 result: %{"reason" => "setup_error", "message" => "the user is gone"}
               } = failed = reload(bulk_action)

        assert statuses(bulk_action) == [:resolved, :resolved]
        assert created(ctx) == []

        # A failed start is over: it isn't started again.
        assert :ok = Worker.run_now(bulk_action.id)

        owner(AshBulkDurable.Test.Owner)

        # The verdict frees the owner to submit again...
        other = submit!(ctx, 1)
        assert %{status: :queued} = other
        Repo.query!("DELETE FROM bulk_actions WHERE id = $1", [Ecto.UUID.dump!(other.id)])

        # ...and a retry, once the cause is fixed, starts the count again.
        assert {:ok, _retried} = AshBulkDurable.retry(failed, scope: ctx.scope)
        assert %{setup_failures: 0} = reload(bulk_action)
        assert :ok = Worker.run_now(bulk_action.id)
        assert %{status: :completed} = reload(bulk_action)
      end
    end

    test "a start whose score rose sets the count back to 0", ctx do
      bulk_action = submit!(ctx, 2)
      # Two failed setups, the last start scoring no row moved on; since then
      # both rows resolved.
      set!(bulk_action, "status = 'running', progress_at_start = 0, setup_failures = 2")
      owner(RaisingOwner)

      capture_log(fn -> assert {%RuntimeError{}, _} = attempt(bulk_action) end)

      assert %{status: :running, progress_at_start: 2, setup_failures: 1} = reload(bulk_action)
    end

    test "a kill isn't counted, but the stalled starts after it fail it as crashed", ctx do
      bulk_action = submit!(ctx, 2)
      owner(KillingOwner)

      # Three stalled starts enter isolation, whose runs die before their
      # first row too: two more, the attempts a row run alone may take, and
      # three more, the setup failures allowed, still move none.
      capture_log(fn ->
        for stalled <- 0..8 do
          assert :killed = attempt(bulk_action)

          assert %{status: :running, stalled_starts: ^stalled, setup_failures: 0} =
                   reload(bulk_action)
        end
      end)

      # The next start fails it, running nothing.
      log = capture_log(fn -> assert {:ran, :ok} = attempt(bulk_action) end)

      assert log =~
               "made no progress in its last 9 starts, even running its rows one at a time"

      assert %{
               status: :failed,
               stalled_starts: 9,
               setup_failures: 0,
               result: %{"reason" => "crashed"}
             } = failed = reload(bulk_action)

      assert statuses(bulk_action) == [:resolved, :resolved]
      assert attempts(bulk_action) == [0, 0]
      assert created(ctx) == []

      # A retry, once the cause is fixed, starts the count again.
      owner(AshBulkDurable.Test.Owner)
      assert {:ok, _retried} = AshBulkDurable.retry(failed, scope: ctx.scope)
      assert %{stalled_starts: 0} = reload(bulk_action)
      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed} = reload(bulk_action)
    end

    test "the stalled starts it takes follow all three limits", ctx do
      config(:max_stalled_starts, 1)
      config(:max_row_attempts, 1)
      config(:max_setup_failures, 2)
      bulk_action = submit!(ctx, 2)
      owner(KillingOwner)

      capture_log(fn ->
        for _start <- 1..5, do: assert(:killed = attempt(bulk_action))
        assert %{status: :running, stalled_starts: 4} = reload(bulk_action)

        assert {:ran, :ok} = attempt(bulk_action)
      end)

      assert %{status: :failed, stalled_starts: 5, result: %{"reason" => "crashed"}} =
               reload(bulk_action)
    end

    test "a row that kills its run, with runs dying before any row between, still fails alone",
         ctx do
      bulk_action = submit!(ctx, 3, chunk_size: 3)
      kill_on_row(ctx, 1)

      capture_log(fn ->
        # Three stalled starts, then isolation: row 1 kills its run, bumped
        # once.
        for _start <- 1..4, do: assert(:killed = attempt(bulk_action))
        assert %{stalled_starts: 3} = reload(bulk_action)
        assert attempts(bulk_action) == [1, 0, 0]

        # As many runs as may raise in their setup die there instead.
        owner(KillingOwner)
        for _start <- 1..3, do: assert(:killed = attempt(bulk_action))
        owner(AshBulkDurable.Test.Owner)

        # Row 1 kills its run once more...
        assert :killed = attempt(bulk_action)
        assert %{status: :running, stalled_starts: 7} = reload(bulk_action)
        assert attempts(bulk_action) == [2, 0, 0]

        # ...and the next start, the last one the limit allows, fails it
        # without running it, and runs the rest.
        assert {:ran, :ok} = attempt(bulk_action)
      end)

      assert %{stalled_starts: 8} = reload(bulk_action)
      assert statuses(bulk_action) == [:failed, :succeeded, :succeeded]
      assert %{status: :completed_with_errors} = reload(bulk_action)
    end

    test "one that finds the lock held at its count counts nothing, and still raises", ctx do
      bulk_action = submit!(ctx, 2)
      owner(RaisingOwner)

      # Once the run's start has committed, another transaction takes the lock.
      test_pid = self()

      attach([:ash_bulk_durable, :bulk_action, :start], fn _measurements, metadata ->
        if metadata.bulk_action_id == bulk_action.id do
          send(test_pid, {:started, self()})
          assert_receive :locked, 5_000
        end
      end)

      capture_log(fn ->
        run = Task.async(fn -> attempt(bulk_action) end)
        assert_receive {:started, started}, 5_000
        locker = lock_elsewhere(bulk_action.id)
        send(started, :locked)
        assert {%RuntimeError{}, _} = Task.await(run, 15_000)
        release(locker)
      end)

      assert %{status: :running, setup_failures: 0} = reload(bulk_action)
    end

    test "one whose pass a retry moved on counts nothing, and still raises", ctx do
      bulk_action = submit!(ctx, 2)
      owner(RaisingOwner)

      # Once the run's start has committed, a retry moves the pass on, as
      # one that reopened the bulk action while this run was still setting up.
      attach([:ash_bulk_durable, :bulk_action, :start], fn _measurements, metadata ->
        if metadata.bulk_action_id == bulk_action.id, do: set!(bulk_action, "pass = pass + 1")
      end)

      capture_log(fn -> assert {%RuntimeError{}, _} = attempt(bulk_action) end)

      assert %{status: :running, pass: 1, setup_failures: 0} = reload(bulk_action)
    end
  end

  describe "a retry" do
    test "starts the count again", ctx do
      bulk_action = submit!(ctx, 2)
      assert :ok = Worker.run_now(bulk_action.id)
      [r1, r2] = rows(bulk_action)

      # As a bulk action that failed a row as crashed leaves it.
      set_row!(r2, "status = 'failed', attempts = 2")

      set!(
        bulk_action,
        "status = 'completed_with_errors', rows_done = 1, stalled_starts = 4, " <>
          "setup_failures = 2, progress_at_start = 3, shutdown_stopped = true, isolating_row_id = $2",
        [Ecto.UUID.dump!(r2.id)]
      )

      set_row!(r1, "attempts = 1")

      assert {:ok, _retried} = Retry.retry(reload(bulk_action), scope: ctx.scope)

      assert %{
               status: :queued,
               stalled_starts: 0,
               setup_failures: 0,
               progress_at_start: nil,
               shutdown_stopped: false,
               isolating_row_id: nil
             } = reload(bulk_action)

      # The reopened row's attempts go; the one that succeeded keeps its own.
      assert [%{status: :succeeded, attempts: 1}, %{status: :resolved, attempts: 0}] =
               rows(bulk_action)
    end
  end

  describe "giving a bump back" do
    test "a shutdown after a suspect resolved alone, while the run goes on, leaves its attempts",
         ctx do
      bulk_action = submit_resolving!(ctx, [{EchoResolver, "a"}, {KillingResolver, "b"}])
      [r1, _r2] = rows(bulk_action)
      # A run died on row 1 once, while running it alone.
      set_row!(r1, "attempts = 1")

      # Row 1 resolves alone, bumped and given back, which ends its isolation;
      # then row 2 stops the run as it resolves with the rest.
      assert :killed = attempt(bulk_action)
      assert [%{status: :resolved, attempts: 1}, %{status: :pending}] = rows(bulk_action)
      assert %{isolating_row_id: nil} = reload(bulk_action)

      # As if the poller's shutdown had stopped that run.
      set!(bulk_action, "shutdown_stopped = true")
      assert :killed = attempt(bulk_action)

      # Its bump was given back once already, so its earlier death still counts.
      assert [%{status: :resolved, attempts: 1}, _r2] = rows(bulk_action)
    end

    test "a shutdown's give-back never takes a row below 0", ctx do
      bulk_action = submit!(ctx, 1)
      [r1] = rows(bulk_action)

      # A shutdown stopped the last run while it named row 1, whose bump is
      # already gone.
      set!(bulk_action, "status = 'running', shutdown_stopped = true, isolating_row_id = $2", [
        Ecto.UUID.dump!(r1.id)
      ])

      assert {:ran, :ok} = attempt(bulk_action)
      assert [%{status: :succeeded, attempts: 0}] = rows(bulk_action)
      assert %{status: :completed} = reload(bulk_action)
    end

    test "a resolve's give-back takes one from the committed count, never going below 0", ctx do
      bulk_action = submit_resolving!(ctx, [{ResettingResolver, ctx.user.id}])
      [r1] = rows(bulk_action)
      # A suspect: bumped to 2 to resolve alone, its bumps taken back meanwhile.
      set_row!(r1, "attempts = 1")

      assert {:ran, :ok} = attempt(bulk_action)

      # No attempts left, so it ran with the rest in phase 2.
      assert [%{status: :succeeded, attempts: 0}] = rows(bulk_action)
      assert %{status: :completed} = reload(bulk_action)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

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

  # One row a resolver for each, resolving the row's native name.
  defp submit_resolving!(ctx, resolvers) do
    rows =
      resolvers
      |> Enum.with_index(1)
      |> Enum.map(fn {{resolver, value}, i} ->
        %{
          input: %{
            code: "#{ctx.tag}-#{i}",
            name: "#{ctx.tag} N#{i}",
            native_name: {:resolve, resolver, value}
          }
        }
      end)

    Ash.create!(
      BulkAction,
      %{
        user_id: ctx.user.id,
        resource_name: inspect(Region),
        action_name: :create,
        action_type: :create,
        total_rows: length(rows),
        mode: :per_row,
        chunk_size: 1,
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  # Kills the run writing the region of row `i`, inside the transaction
  # that writes it, which then commits nothing.
  defp kill_on_row(ctx, i) do
    code = "#{ctx.tag}-#{i}"

    attach([:ash_bulk_durable, :test, :repo, :query], fn _measurements, metadata ->
      if metadata.source == "regions" and String.starts_with?(metadata.query, "INSERT") and
           code in List.flatten(metadata.params),
         do: Process.exit(self(), :kill)
    end)
  end

  # The codes in each insert of the bulk action's regions, in order.
  defp collect_inserts(ctx) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    attach([:ash_bulk_durable, :test, :repo, :query], fn _measurements, metadata ->
      case inserted_codes(ctx, metadata) do
        [] -> :ok
        codes -> Agent.update(agent, &[codes | &1])
      end
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() end
  end

  defp inserted_codes(ctx, %{source: "regions", query: "INSERT" <> _, params: params}) do
    params
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, ctx.tag <> "-")))
    |> Enum.sort()
  end

  defp inserted_codes(_ctx, _metadata), do: []

  # The bulk action's `event`s, as `{measurements, metadata}`, in order.
  defp collect(event, bulk_action) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    attach(event, fn measurements, metadata ->
      if metadata.bulk_action_id == bulk_action.id,
        do: Agent.update(agent, &[{measurements, metadata} | &1])
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() end
  end

  @doc false
  def handle(_event, measurements, metadata, fun), do: fun.(measurements, metadata)

  defp attach(event, fun) do
    handler = "crash-test-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, &__MODULE__.handle/4, fun)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # One start of the bulk action, in a process of its own, as a poller's
  # would be: `:killed` when it died, `{:ran, result}` when it returned. A
  # killed run's lock goes with its connection, so it waits for that.
  defp attempt(bulk_action) do
    Process.put(:starts, Process.get(:starts, 0) + 1)

    {pid, monitor} =
      spawn_monitor(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        exit({:ran, Worker.run_now(bulk_action.id)})
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 10_000
    if reason == :killed, do: assert(eventually(fn -> lockable?(bulk_action.id) end))
    reason
  end

  defp starts(_bulk_action), do: Process.get(:starts, 0)

  # `key` in the `ash_bulk_durable` config, until the test ends.
  defp config(key, value) do
    previous = Application.fetch_env(:ash_bulk_durable, key)
    Application.put_env(:ash_bulk_durable, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous} -> Application.put_env(:ash_bulk_durable, key, previous)
        :error -> Application.delete_env(:ash_bulk_durable, key)
      end
    end)
  end

  # The owner every run rebuilds its scope with, until the test ends.
  defp owner(module) do
    previous = Application.fetch_env!(:ash_bulk_durable, :owner_module)
    Application.put_env(:ash_bulk_durable, :owner_module, module)
    on_exit(fn -> Application.put_env(:ash_bulk_durable, :owner_module, previous) end)
  end

  # Starts the bulk action until it is finished, and returns how many starts
  # that took.
  defp run_until_finished(bulk_action, limit \\ 20) do
    Enum.reduce_while(1..limit, 0, fn start, _starts ->
      attempt(bulk_action)

      if reload(bulk_action).status in [:queued, :running],
        do: {:cont, start},
        else: {:halt, start}
    end)
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp statuses(bulk_action), do: Enum.map(rows(bulk_action), & &1.status)
  defp attempts(bulk_action), do: Enum.map(rows(bulk_action), & &1.attempts)

  defp reload(bulk_action), do: Ash.get!(BulkAction, bulk_action.id, authorize?: false)

  defp set!(bulk_action, set, params \\ []) do
    Repo.query!(
      "UPDATE bulk_actions SET #{set} WHERE id = $1",
      [Ecto.UUID.dump!(bulk_action.id) | params]
    )
  end

  defp set_row!(row, set) do
    Repo.query!("UPDATE bulk_action_rows SET #{set} WHERE id = $1", [Ecto.UUID.dump!(row.id)])
  end

  # The codes of the regions the bulk action created.
  defp created(ctx) do
    %{rows: rows} = Repo.query!("SELECT code FROM regions WHERE code LIKE $1 || '-%'", [ctx.tag])
    rows |> List.flatten() |> Enum.sort()
  end

  defp codes(ctx, indexes), do: Enum.map(indexes, &"#{ctx.tag}-#{&1}")

  # Holds the bulk action's row lock from a connection of its own until told.
  defp lock_elsewhere(id) do
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

    assert_receive :locked, 2_000
    pid
  end

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
    Ash.create!(User, %{name: "Crash", email: "#{tag}@example.test"},
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
    Repo.query!("DELETE FROM regions WHERE code LIKE $1 || '-%'", [tag])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [email])
  end
end
