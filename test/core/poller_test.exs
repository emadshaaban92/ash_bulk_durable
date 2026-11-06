defmodule AshBulkDurable.Core.PollerTest do
  @moduledoc """
  The poller, the liveness hint it reads, and a bulk action resumed after its
  run died. The hint is stamped on the database's clock, which stands still
  inside the sandbox's one transaction, and the poller's runs, a lock held
  elsewhere and a killed run each need connections of their own. So this test
  runs outside the sandbox, every process checking out a connection of its
  own, and deletes what it wrote.
  """
  use ExUnit.Case, async: false

  import AshBulkDurable.StorageHelpers
  import ExUnit.CaptureLog

  require Ash.Query

  defmodule SlowResolver do
    @moduledoc "Resolves a value to itself, after a while."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context) do
      Process.sleep(600)
      {:ok, value}
    end

    @impl true
    def finish(nil), do: :ok
  end

  defmodule RaisingStorage do
    @moduledoc "A store that is down."
    def get_object(_key), do: raise("storage is down")
    def list_objects(_prefix), do: {:ok, []}
    def delete_object(_key), do: :ok
  end

  alias AshBulkDurable.Core.{Liveness, Poller, Worker}
  alias AshBulkDurable.Test.{BulkAction, Region, Repo, Row, Scope, User}
  alias AshBulkDurable.TestStorage

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    tag = "poll#{System.unique_integer([:positive])}"

    on_exit(fn ->
      cleanup(tag)
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    %{tag: tag}
  end

  # ── The poller ──────────────────────────────────────────────────────────

  describe "the poller" do
    test "starts queued bulk actions oldest first, at most :max_running at once, " <>
           "and fills a slot as soon as a run ends",
         ctx do
      [first, second, third] = Enum.map(1..3, fn i -> submit!(ctx, 1, user: "u#{i}") end)
      hold_runs([first, second, third])
      start_poller!(max_running: 2)

      Poller.nudge()
      assert_receive {:started, id1, run1}, 2_000
      assert_receive {:started, id2, run2}, 2_000
      # The two oldest; their runs start concurrently, in either order.
      assert Enum.sort([id1, id2]) == Enum.sort([first.id, second.id])

      # Full: a nudge starts nothing, not even another run of its own two.
      Poller.nudge()
      refute_receive {:started, _id, _run}, 300
      assert Enum.sort(Poller.running()) == Enum.sort([first.id, second.id])

      send(run1, :go)
      assert_receive {:started, id3, run3}, 2_000
      assert id3 == third.id

      for run <- [run2, run3], do: send(run, :go)
      await_idle()
      assert Enum.map([first, second, third], &reload(&1).status) == List.duplicate(:completed, 3)
    end

    test "leaves a :running bulk action with a fresh hint alone, and starts a stale one", ctx do
      fresh = submit!(ctx, 1, user: "fresh")
      stale = submit!(ctx, 1, user: "stale")
      set_running!(fresh, "now() AT TIME ZONE 'utc'")
      set_running!(stale, "(now() AT TIME ZONE 'utc') - interval '10 minutes'")
      starts = count_starts([fresh, stale])
      start_poller!(stale_after: :timer.minutes(2))

      Poller.nudge()
      await_idle()

      assert starts.() == %{fresh.id => 0, stale.id => 1}
      assert %{status: :running, rows_done: 0} = reload(fresh)
      assert %{status: :completed, rows_done: 1} = reload(stale)
    end

    test "a :running bulk action never stamped is stale", ctx do
      unstamped = submit!(ctx, 1)
      set_running!(unstamped, "NULL")
      start_poller!()

      Poller.nudge()
      await_idle()
      assert %{status: :completed} = reload(unstamped)
    end

    test "is nudged by a submit and a retry, without waiting for its poll", ctx do
      start_poller!(poll_interval: :timer.hours(1))
      taken!(ctx, 2)

      bulk_action = submit!(ctx, 2)
      assert eventually(fn -> reload(bulk_action).status == :completed_with_errors end)

      # Just finished, its hint is fresh: the retry sheds it.
      Repo.query!("DELETE FROM regions WHERE name = $1", ["#{ctx.tag} X2"])
      {:ok, _retried} = AshBulkDurable.retry(reload(bulk_action), scope: scope(ctx))
      assert eventually(fn -> reload(bulk_action).status == :completed end)
    end

    test "a submit inside the caller's transaction nudges no poller", ctx do
      # This process stands in for the poller, under its name.
      Process.register(self(), Poller)
      on_exit(fn -> if Process.whereis(Poller) == self(), do: Process.unregister(Poller) end)

      {:ok, _bulk_action} =
        Repo.transaction(fn ->
          bulk_action = submit!(ctx, 1, user: "inside")
          refute_received :nudge
          bulk_action
        end)

      refute_received :nudge
      _outside = submit!(ctx, 1, user: "outside")
      assert_received :nudge
      Process.unregister(Poller)
    end

    test "skips bulk actions another transaction holds, so newer ones still start", ctx do
      [old1, old2] = Enum.map(1..2, fn i -> submit!(ctx, 1, user: "old#{i}") end)
      newer = submit!(ctx, 1, user: "newer")

      lockers =
        for old <- [old1, old2] do
          set_running!(old, "(now() AT TIME ZONE 'utc') - interval '10 minutes'")
          lock_elsewhere(old.id)
        end

      starts = count_starts([old1, old2, newer])
      start_poller!(max_running: 2, poll_interval: 100)
      assert eventually(fn -> reload(newer).status == :completed end)
      Process.sleep(300)

      # Never started while held: not even a run that would find them busy.
      assert starts.() == %{old1.id => 0, old2.id => 0, newer.id => 1}
      assert Enum.map([old1, old2], &reload(&1).status) == [:running, :running]

      Enum.each(lockers, &release/1)
      assert eventually(fn -> Enum.all?([old1, old2], &(reload(&1).status == :completed)) end)
    end

    test "logs a run that crashes, frees its slot and fills it", ctx do
      [crashing, next] = Enum.map(1..2, fn i -> submit!(ctx, 1, user: "u#{i}") end)
      crashes = :counters.new(1, [])

      # Its first run dies before it starts, so it is still queued, and the
      # oldest: the freed slot goes to it again.
      attach([:ash_bulk_durable, :worker_attempt, :start], fn %{bulk_action_id: id} ->
        if id == crashing.id and :counters.get(crashes, 1) == 0 do
          :counters.add(crashes, 1, 1)
          Process.exit(self(), :kill)
        end
      end)

      log =
        capture_log(fn ->
          start_poller!(max_running: 1)
          Poller.nudge()
          assert eventually(fn -> reload(next).status == :completed end)
        end)

      assert log =~ "bulk action #{crashing.id} crashed: killed"
      assert eventually(fn -> reload(crashing).status == :completed end)
    end

    test "on shutdown lets a running chunk finish within the grace period", ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      slow_chunk(bulk_action, 300)
      start_poller!(shutdown_grace: 3_000)

      Poller.nudge()
      assert_receive {:chunk_started, _run}, 2_000
      stop_supervised!(Poller)

      assert %{status: :completed, rows_done: 2} = reload(bulk_action)
      assert created(ctx) == codes(ctx, 1..2)
    end

    test "on shutdown kills a run past the grace period, committing nothing of its chunk",
         ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      slow_chunk(bulk_action, 5_000)
      start_poller!(shutdown_grace: 200)

      Poller.nudge()
      assert_receive {:chunk_started, run}, 2_000
      monitor = Process.monitor(run)
      capture_log(fn -> stop_supervised!(Poller) end)
      assert_receive {:DOWN, ^monitor, :process, ^run, :killed}, 1_000

      assert eventually(fn -> lockable?(bulk_action.id) end)
      assert created(ctx) == []
      assert Enum.map(rows(bulk_action), & &1.status) == [:resolved, :resolved]
      assert %{status: :running, rows_done: 0} = reload(bulk_action)
    end

    test "on shutdown marks a run it kills, so its next start counts no stall and gives a bump back",
         ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      [r1, _r2] = rows(bulk_action)
      test_pid = self()

      # Three starts without progress so far, both rows `:resolved` at each:
      # the next start runs the rows alone.
      Repo.query!(
        "UPDATE bulk_actions SET stalled_starts = 3, progress_at_start = 2 WHERE id = $1",
        [Ecto.UUID.dump!(bulk_action.id)]
      )

      # The poller's run of row 1, alone, outlasts the grace period.
      attach([:ash_bulk_durable, :test, :repo, :query], fn metadata ->
        if self() != test_pid and metadata.source == "regions" and
             String.starts_with?(metadata.query, "INSERT") do
          send(test_pid, {:row_running, self()})
          Process.sleep(5_000)
        end
      end)

      start_poller!(shutdown_grace: 200)
      Poller.nudge()
      assert_receive {:row_running, run}, 2_000
      monitor = Process.monitor(run)
      log = capture_log(fn -> stop_supervised!(Poller) end)
      assert_receive {:DOWN, ^monitor, :process, ^run, :killed}, 1_000
      refute log =~ "couldn't be marked"

      assert %{status: :running, stalled_starts: 4, shutdown_stopped: true, isolating_row_id: id} =
               reload(bulk_action)

      assert id == r1.id

      assert [%{status: :resolved, attempts: 1}, %{status: :resolved, attempts: 0}] =
               rows(bulk_action)

      # The next start counts no stall, and row 1 runs alone again with its
      # bump given back first.
      capture_log(fn -> assert :ok = Worker.run_now(bulk_action.id) end)

      assert %{status: :completed, stalled_starts: 4, shutdown_stopped: false} =
               reload(bulk_action)

      assert [%{status: :succeeded, attempts: 1}, %{attempts: 1}] = rows(bulk_action)
      assert created(ctx) == codes(ctx, 1..2)
    end

    test "sets the child spec's shutdown above the grace period" do
      assert %{shutdown: shutdown} = Poller.child_spec(shutdown_grace: 20_000)
      assert shutdown > 20_000
    end
  end

  describe "the staged-file sweep" do
    setup do
      put_config(:storage, TestStorage)
      start_supervised!(TestStorage)
      key = "bulk-staging/#{Ecto.UUID.generate()}/uuid/companions/logo.zip"
      TestStorage.put(key, "x", DateTime.add(DateTime.utc_now(), -2, :day))
      %{key: key}
    end

    test "runs on its interval, the first within it", %{key: key} do
      start_poller!(staging_sweep_interval: 100)
      assert eventually(fn -> key not in TestStorage.keys() end)

      # And again.
      TestStorage.put(key, "x", DateTime.add(DateTime.utc_now(), -2, :day))
      assert eventually(fn -> key not in TestStorage.keys() end)
    end

    test "never runs with staging_sweep_interval: nil", %{key: key} do
      poller = start_poller!(staging_sweep_interval: nil)
      Process.sleep(300)
      assert key in TestStorage.keys()
      assert %{sweep_timer: nil} = :sys.get_state(poller)
    end

    test "is first scheduled within the first hour of a daily interval" do
      poller = start_poller!(staging_sweep_interval: :timer.hours(24))
      %{sweep_timer: timer} = :sys.get_state(poller)
      assert Process.read_timer(timer) <= :timer.hours(1)
    end
  end

  describe "without a poller" do
    setup do
      put_config(:warn_without_poller, true)
      :persistent_term.erase({Poller, :warned})
      on_exit(fn -> :persistent_term.erase({Poller, :warned}) end)
    end

    test "a nudge warns once per node" do
      log = capture_log(fn -> for _ <- 1..3, do: Poller.nudge() end)
      assert [_once] = Regex.scan(~r/no AshBulkDurable.Core.Poller runs on this node/, log)
    end

    test "warns nothing with warn_without_poller: false" do
      put_config(:warn_without_poller, false)
      assert capture_log(fn -> Poller.nudge() end) == ""
    end
  end

  # ── The liveness hint ───────────────────────────────────────────────────

  describe "the liveness hint" do
    setup do
      put_config(:alive_interval, :timer.hours(1))
    end

    test "is stamped by the run's start and by every chunk it commits", ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 1)
      test_pid = self()

      # Read from the database on each one's own connection, as committed.
      for event <- [[:ash_bulk_durable, :phase1, :start], [:ash_bulk_durable, :chunk, :stop]] do
        attach(event, fn %{bulk_action_id: id} ->
          if id == bulk_action.id, do: send(test_pid, {:alive_at, committed_alive_at(id)})
          Process.sleep(5)
        end)
      end

      assert :ok = Worker.run_now(bulk_action.id)

      assert_received {:alive_at, %DateTime{} = started}
      assert_received {:alive_at, %DateTime{} = chunk1}
      assert_received {:alive_at, %DateTime{} = chunk2}
      assert DateTime.before?(started, chunk1)
      assert DateTime.before?(chunk1, chunk2)
    end

    test "is stamped by the ticker during a slow phase-1 row", ctx do
      put_config(:alive_interval, 100)
      bulk_action = submit_resolving!(ctx)
      test_pid = self()

      attach([:ash_bulk_durable, :phase1, :start], fn %{bulk_action_id: id} ->
        if id == bulk_action.id, do: send(test_pid, {:before, committed_alive_at(id)})
      end)

      attach([:ash_bulk_durable, :phase1, :stop], fn %{bulk_action_id: id} ->
        if id == bulk_action.id, do: send(test_pid, {:after, committed_alive_at(id)})
      end)

      assert :ok = Worker.run_now(bulk_action.id)
      assert_received {:before, %DateTime{} = before}
      assert_received {:after, %DateTime{} = later}
      assert DateTime.diff(later, before, :millisecond) >= 300
    end

    test "the ticker skips its stamp, without waiting, while another transaction holds the lock",
         ctx do
      bulk_action = submit!(ctx, 1)
      set_running!(bulk_action, "(now() AT TIME ZONE 'utc') - interval '1 hour'")
      before = committed_alive_at(bulk_action.id)
      put_config(:alive_interval, 50)

      locker = lock_elsewhere(bulk_action.id)
      ticker = Liveness.start_ticker(bulk_action.id)

      for _ <- 1..10 do
        Process.sleep(30)
        refute waiting_for_lock?()
      end

      assert committed_alive_at(bulk_action.id) == before
      release(locker)

      assert eventually(fn -> committed_alive_at(bulk_action.id) != before end)
      assert :ok = Liveness.stop_ticker(ticker)
      refute Process.alive?(ticker)
    end

    test "if_stale_after leaves a freshly stamped bulk action alone; run_now/1 ignores it",
         ctx do
      bulk_action = submit!(ctx, 1)
      set_running!(bulk_action, "now() AT TIME ZONE 'utc'")
      stamped = reload(bulk_action)

      assert :busy = Worker.run(bulk_action.id, if_stale_after: :timer.minutes(2))

      assert reload(bulk_action) |> Map.take([:status, :rows_done, :alive_at, :updated_at]) ==
               Map.take(stamped, [:status, :rows_done, :alive_at, :updated_at])

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed} = reload(bulk_action)
    end

    test "if_stale_after starts a bulk action whose hint is older, and a queued one", ctx do
      stale = submit!(ctx, 1, user: "stale")
      queued = submit!(ctx, 1, user: "queued")
      set_running!(stale, "(now() AT TIME ZONE 'utc') - interval '10 minutes'")

      assert :ok = Worker.run(stale.id, if_stale_after: :timer.minutes(2))
      assert :ok = Worker.run(queued.id, if_stale_after: :timer.minutes(2))
      assert %{status: :completed} = reload(stale)
      assert %{status: :completed} = reload(queued)
    end
  end

  describe "the run's own ticker" do
    test "never stops the run, however often it ticks", ctx do
      put_config(:alive_interval, 1)
      bulk_action = submit!(ctx, 100, chunk_size: 1)

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed, rows_done: 100} = reload(bulk_action)
    end

    test "stops with a run that raises", ctx do
      put_config(:alive_interval, 50)
      put_config(:storage, RaisingStorage)

      bulk_action =
        submit_resolving!(ctx, %{staged_files: %{"logo" => "bulk-staging/x/logo.zip"}})

      {pid, monitor} =
        spawn_monitor(fn ->
          assert_raise RuntimeError, "storage is down", fn -> Worker.run_now(bulk_action.id) end
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      assert %{status: :running} = reload(bulk_action)
      after_raise = committed_alive_at(bulk_action.id)

      Process.sleep(250)
      assert committed_alive_at(bulk_action.id) == after_raise
    end
  end

  # ── Resume ──────────────────────────────────────────────────────────────

  describe "a run killed in the middle of a chunk" do
    test "commits nothing of it, and once its hint is stale a poller runs it to its verdict",
         ctx do
      put_config(:alive_interval, :timer.hours(1))
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      short_name = Ash.Domain.Info.short_name(AshBulkDurable.Test.Domain)

      # The first target is written, the second not yet, nothing committed.
      attach([:ash, short_name, :create, :stop], fn metadata ->
        if metadata[:resource_short_name] == :region and Process.get(:doomed?),
          do: Process.exit(self(), :kill)
      end)

      {pid, monitor} =
        spawn_monitor(fn ->
          Process.put(:doomed?, true)
          Worker.run_now(bulk_action.id)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      assert eventually(fn -> lockable?(bulk_action.id) end)
      assert created(ctx) == []
      assert Enum.map(rows(bulk_action), & &1.status) == [:resolved, :resolved]
      assert %{status: :running, rows_done: 0, alive_at: %DateTime{}} = reload(bulk_action)

      starts = count_starts([bulk_action])
      start_poller!(stale_after: 1_000, poll_interval: 100)

      # Fresh, so left alone a while: it might still be alive.
      Process.sleep(300)
      assert starts.() == %{bulk_action.id => 0}

      assert eventually(fn -> reload(bulk_action).status == :completed end)
      assert starts.() == %{bulk_action.id => 1}
      assert created(ctx) == codes(ctx, 1..2)
      assert %{rows_done: 2} = reload(bulk_action)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp start_poller!(opts \\ []) do
    start_supervised!(
      {Poller,
       Keyword.merge(
         [poll_interval: :timer.hours(1), staging_sweep_interval: nil, shutdown_grace: 1_000],
         opts
       )}
    )
  end

  defp scope(ctx, user \\ "owner"), do: Scope.new(actor: user!(ctx, user))

  defp user!(ctx, name) do
    email = "#{name}.#{ctx.tag}@example.test"

    case Ash.read_one!(Ash.Query.filter(User, email == ^email), authorize?: false) do
      nil ->
        Ash.create!(User, %{name: name, email: email}, action: :create_super, authorize?: false)

      user ->
        user
    end
  end

  defp submit!(ctx, count, opts \\ []) do
    {user, opts} = Keyword.pop(opts, :user, "owner")

    inputs =
      Enum.map(1..count, fn i ->
        %{
          code: "#{ctx.tag}-#{user}-#{i}",
          name: "#{ctx.tag} #{user} N#{i}",
          native_name: "#{ctx.tag} #{user} A#{i}"
        }
      end)

    {:ok, bulk_action} =
      AshBulkDurable.bulk_create(
        inputs,
        Region,
        :create,
        Keyword.merge([scope: scope(ctx, user), chunk_size: 1], opts)
      )

    bulk_action
  end

  # One row whose native name resolves slowly in phase 1.
  defp submit_resolving!(ctx, attrs \\ %{}) do
    Ash.create!(
      BulkAction,
      Map.merge(
        %{
          user_id: user!(ctx, "owner").id,
          resource_name: "AshBulkDurable.Test.Region",
          action_name: :create,
          action_type: :create,
          total_rows: 1,
          mode: :per_row,
          chunk_size: 1,
          rows: [
            %{
              input: %{
                code: "#{ctx.tag}-owner-1",
                name: "#{ctx.tag} owner N1",
                native_name: {:resolve, SlowResolver, "#{ctx.tag} A1"}
              }
            }
          ]
        },
        attrs
      ),
      action: :create,
      authorize?: false
    )
  end

  # A region row `i` of the owner's bulk action would create already exists,
  # so that row fails.
  defp taken!(ctx, i) do
    Ash.create!(
      Region,
      %{code: "#{ctx.tag}-owner-#{i}", name: "#{ctx.tag} X#{i}", native_name: "X#{i}"},
      authorize?: false
    )
  end

  defp set_running!(bulk_action, alive_at) do
    Repo.query!(
      "UPDATE bulk_actions SET status = 'running', started_at = now(), " <>
        "alive_at = #{alive_at} WHERE id = $1",
      [Ecto.UUID.dump!(bulk_action.id)]
    )
  end

  defp committed_alive_at(id) do
    Task.async(fn -> Ash.get!(BulkAction, id, authorize?: false).alive_at end)
    |> Task.await()
  end

  defp reload(bulk_action), do: Ash.get!(BulkAction, bulk_action.id, authorize?: false)

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  # The codes of the owner's regions the bulk action created.
  defp created(ctx) do
    %{rows: rows} =
      Repo.query!(
        "SELECT code FROM regions WHERE code LIKE $1 || '-owner-%' AND name NOT LIKE '%X%'",
        [
          ctx.tag
        ]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp codes(ctx, range), do: Enum.map(range, &"#{ctx.tag}-owner-#{&1}")

  # Each run of these bulk actions waits, once started, until told `:go`.
  defp hold_runs(bulk_actions) do
    ids = Enum.map(bulk_actions, & &1.id)
    test_pid = self()

    attach([:ash_bulk_durable, :worker_attempt, :start], fn %{bulk_action_id: id} ->
      if id in ids do
        send(test_pid, {:started, id, self()})

        receive do
          :go -> :ok
        end
      end
    end)
  end

  # The bulk action's chunk sleeps `ms` inside its transaction, holding the
  # lock, telling the test it began.
  defp slow_chunk(bulk_action, ms) do
    test_pid = self()

    attach([:ash_bulk_durable, :chunk, :start], fn %{bulk_action_id: id} ->
      if id == bulk_action.id do
        send(test_pid, {:chunk_started, self()})
        Process.sleep(ms)
      end
    end)
  end

  # How many runs of each bulk action started.
  defp count_starts(bulk_actions) do
    counters = Map.new(bulk_actions, &{&1.id, :counters.new(1, [])})

    attach([:ash_bulk_durable, :worker_attempt, :start], fn %{bulk_action_id: id} ->
      if counter = counters[id], do: :counters.add(counter, 1, 1)
    end)

    fn -> Map.new(counters, fn {id, counter} -> {id, :counters.get(counter, 1)} end) end
  end

  @doc false
  def handle(_event, _measurements, metadata, fun), do: fun.(metadata)

  defp attach(event, fun) do
    handler = "poller-test-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, &__MODULE__.handle/4, fun)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp await_idle do
    assert eventually(fn -> Poller.running() == [] end)
  end

  defp eventually(fun, tries \\ 250) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
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
  defp lock_elsewhere(id) do
    test_pid = self()

    pid =
      spawn(fn ->
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
    Task.async(fn ->
      {:ok, locked} =
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT 1 FROM bulk_actions WHERE id = $1 FOR NO KEY UPDATE SKIP LOCKED",
            [Ecto.UUID.dump!(id)]
          ).num_rows == 1
        end)

      locked
    end)
    |> Task.await()
  end

  # Every user the test made has an email ending in its tag, and every region
  # a code starting with it.
  defp cleanup(tag) do
    users = "SELECT id FROM users WHERE email LIKE '%.' || $1 || '@example.test'"
    Repo.query!("DELETE FROM bulk_actions WHERE user_id IN (#{users})", [tag])
    Repo.query!("DELETE FROM regions WHERE code LIKE $1 || '-%'", [tag])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [tag])
  end
end
