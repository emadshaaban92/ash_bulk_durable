defmodule AshBulkDurable.OverlapStressTest do
  @moduledoc """
  Runs the whole system as production does, under chaos, and checks the
  invariants the locking design promises.

  Three pollers in this VM compete for a seeded mix of bulk actions, per row
  and all or nothing, with small chunks, rows resolved in phase 1, rows whose
  target returns an error, and rows whose target kills its run every time.
  Some per-row bulk actions run rows with their shared input. Meanwhile a
  driver, this test's process, kills runs and tickers, stops and restarts
  pollers through their shutdown, suspends runs past `:stale_after` (so
  another poller starts the same bulk action), holds a run suspended until
  its bulk action is finished by another run and retried with a corrected
  shared input (so it wakes in a pass it didn't start), holds bulk action
  locks from another connection, and retries, with corrected inputs, or
  abandons bulk actions once they finish.

  It checks each pass at its verdict, and everything once every bulk action
  is finished:

    * every row is applied at most once, under the bulk action's lock, by
      the pass that ran it, with the input it had in that pass, and every
      `:succeeded` row was applied (the target records each committed
      application in its own transaction);
    * every pass has exactly one verdict, written in a transaction (each
      UPDATE setting `finished_at` records what it finished in that same
      transaction), and an abandon one cancel;
    * no row is left `:pending` or `:resolved` under a verdict, except in an
      abandoned bulk action and one failed as `:crashed`, whose rows are left
      as they were;
    * `rows_done` equals the `:succeeded` rows;
    * each row ends as its input says: `:succeeded`, `:failed` with its own
      error, or, for a target that kills its run, `:failed` with
      `CrashedRowError`; an all-or-nothing bulk action with such a row fails
      as `:crashed`;
    * no run, ticker, held lock or open transaction is left.

  A kill is a crash from outside, so a row whose runs the driver killed, or
  suspended with their tickers, at least `:max_row_attempts` times while
  each ran it alone (the bulk action's `isolating_row_id` then) may end
  crashed too, and an all-or-nothing bulk action disrupted so
  `:max_stalled_starts` times in a pass may fail as `:crashed`, as may a
  per-row one disrupted more than `:max_setup_failures` times, the runs
  dying before any row that its give-up allows past isolation and the row
  it kills. The summary
  counts those as excused. A poller's shutdown is no crash, so it excuses
  nothing.

  The first bulk action of every iteration is always one a run can be held
  in until its retry, and holding one goes before any other chaos, so every
  iteration has a run wake in a pass it didn't start.

  Verdicts are seen through the repo's query telemetry, as UPDATEs of
  `bulk_actions` setting `finished_at`: a verdict written some other way,
  such as raw SQL, would read as none, and fail the test.

  Excluded by default. Run it with `mix test --only stress`, sized with:

    * `STRESS_SEED` — the random seed (random when unset, and printed).
    * `STRESS_BULK_ACTIONS` — bulk actions per iteration, 12 by default.
    * `STRESS_ITERATIONS` — iterations, seeded `seed`, `seed + 1`, ..., 1 by
      default.
    * `STRESS_TIMEOUT` — seconds an iteration may take to bring every bulk
      action to a verdict, 120 by default.

  The seed fixes the mix and the driver's choices, not the scheduler: two
  runs on one seed differ in timing. A failure prints the seed and each
  invariant broken, with the bulk action and row.

  Real connections, not the sandbox: runs, tickers, killed runs and a lock
  held elsewhere each need their own, and the liveness hint is stamped on the
  database's clock. It deletes what it wrote.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.{CrashedRowError, Liveness, Poller, Retry, Worker}
  alias AshBulkDurable.EchoResolver
  alias AshBulkDurable.Stress.Applied
  alias AshBulkDurable.Test.{BulkAction, Repo, Row, Scope, User}

  @moduletag :stress
  @moduletag timeout: :infinity

  @pollers 3
  @poll_interval 50
  @stale_after 500
  @alive_interval 100
  @shutdown_grace 100
  @max_running 2
  @max_retries 2

  @terminal [:completed, :completed_with_errors, :failed, :cancelled]

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS stress_applied (
      id uuid PRIMARY KEY, owner_id uuid NOT NULL, row_index integer NOT NULL,
      value text NOT NULL, pass integer
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS stress_verdicts (
      bulk_action_id uuid, pass integer, status text, in_transaction boolean NOT NULL
    )
    """)

    previous = Application.get_env(:ash_bulk_durable, :alive_interval)
    Application.put_env(:ash_bulk_durable, :alive_interval, @alive_interval)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_bulk_durable, :alive_interval, previous),
        else: Application.delete_env(:ash_bulk_durable, :alive_interval)

      Repo.query!("DROP TABLE IF EXISTS stress_applied")
      Repo.query!("DROP TABLE IF EXISTS stress_verdicts")
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "overlapping runs under chaos keep every invariant" do
    seed = env_integer("STRESS_SEED", :rand.uniform(1_000_000))
    size = env_integer("STRESS_BULK_ACTIONS", 12)
    iterations = env_integer("STRESS_ITERATIONS", 1)
    timeout = :timer.seconds(env_integer("STRESS_TIMEOUT", 120))

    for iteration_seed <- seed..(seed + iterations - 1)//1 do
      IO.puts("\noverlap stress: STRESS_SEED=#{iteration_seed} STRESS_BULK_ACTIONS=#{size}")
      {elapsed, report} = :timer.tc(fn -> iteration(iteration_seed, size, timeout) end)
      IO.puts(summary(report, elapsed))

      if report.violations != [] do
        flunk(
          "overlap stress failed with STRESS_SEED=#{iteration_seed} " <>
            "STRESS_BULK_ACTIONS=#{size}:\n" <>
            Enum.map_join(Enum.reverse(report.violations), "\n", &("  * " <> &1))
        )
      end
    end
  end

  # ── One iteration ───────────────────────────────────────────────────────

  defp iteration(seed, size, timeout) do
    :rand.seed(:exsss, {seed, seed, seed})
    tag = "stress#{seed}x#{System.unique_integer([:positive])}"
    Repo.query!("TRUNCATE stress_applied, stress_verdicts")
    handler = attach_verdict_recorder()

    try do
      capture_log(fn -> send(self(), {:report, run_iteration(tag, size, timeout)}) end)
      assert_received {:report, report}

      # A handler that raises is detached, and would record no more verdicts.
      attached? = Enum.any?(:telemetry.list_handlers([]), &(&1.id == handler))
      check(report, attached?, "the verdict recorder stayed attached", nil, "")
    after
      :telemetry.detach(handler)
      cleanup(tag)
    end
  end

  defp run_iteration(tag, size, timeout) do
    bulk_actions = Map.new(1..size, &submit!(tag, &1))
    supervisor = start_pollers!()

    state = %{
      supervisor: supervisor,
      bulk_actions: bulk_actions,
      pollers: Map.new(1..@pollers, &{poller_name(&1), :up}),
      helpers: 0,
      deadline: System.monotonic_time(:millisecond) + timeout,
      chaos: %{},
      excused: 0,
      violations: []
    }

    state = drive(state)
    state = await_helpers(state)
    state = check_nothing_running(state)
    state = check_verdicts(state)
    state = check_applications(state)
    stop_pollers(supervisor)
    outcomes = state.bulk_actions |> Map.keys() |> Enum.map(&reload(&1).status)
    Map.put(state, :outcomes, Enum.frequencies(outcomes))
  end

  # ── The bulk actions ────────────────────────────────────────────────────

  # Each bulk action has an owner of its own: an owner holds one unresolved
  # bulk action at a time.
  defp submit!(tag, i) do
    user =
      Ash.create!(User, %{name: "Stress #{i}", email: "b#{i}.#{tag}@example.test"},
        action: :create_super,
        authorize?: false
      )

    {mode, classes, resolving?, chunk_size, shared_class} = shape(i)
    shared = if :shared in classes, do: value(shared_class, "#{tag}-b#{i}-shared", 0)

    inputs =
      for {class, j} <- Enum.with_index(classes, 1) do
        if class == :shared,
          do: :shared,
          else: wrap(value(class, "#{tag}-b#{i}-r#{j}", 0), resolving? and :rand.uniform() < 0.6)
      end

    scope = Scope.new(actor: user)

    {:ok, bulk_action} =
      Core.create(
        Applied,
        :apply,
        Enum.map(inputs, &%{input: own_input(&1, user)}),
        scope: scope,
        mode: mode,
        input: shared && %{value: shared, owner_id: user.id},
        chunk_size: chunk_size
      )

    indexes = Enum.map(rows(bulk_action), & &1.row_index)

    {bulk_action.id,
     %{
       index: i,
       user: user,
       scope: scope,
       mode: mode,
       resolving?: resolving?,
       tag: "#{tag}-b#{i}",
       inputs: indexes |> Enum.zip(inputs) |> Map.new(),
       shared: shared,
       expected: %{},
       checked: MapSet.new(),
       retries: 0,
       decision: nil,
       settled?: false,
       abandoned?: false,
       disruptions: %{},
       row_disruptions: %{},
       held: []
     }}
  end

  # The first bulk action of every iteration is the one a run is held in
  # until its retry (see `suspend_run/2`): per row, one row a chunk, half its
  # rows running with a shared input that fails them, so a retry corrects it,
  # and it has rows left long enough to hold a run in.
  defp shape(1) do
    classes = Enum.flat_map(1..8, fn _ -> [:good, :shared] end)
    {:per_row, classes, false, 1, :bad}
  end

  defp shape(_i) do
    mode = if :rand.uniform() < 0.3, do: :all_or_nothing, else: :per_row
    count = Enum.random(3..20)
    resolving? = :rand.uniform() < 0.4
    classes = row_classes(mode, count)
    {mode, classes, resolving?, Enum.random([1, 2, 3, 5, 8, 10]), shared_class()}
  end

  # All or nothing gets rows that kill its run, or rows that fail, not both:
  # which of the two ends it would hang on the order its rows run in.
  # A per-row bulk action may run some rows with its shared input, which a
  # retry can replace: a run that outlived the retry would apply the old one.
  defp row_classes(:per_row, count) do
    kills = if :rand.uniform() < 0.3, do: Enum.random(1..2), else: 0
    shared = if :rand.uniform() < 0.4, do: Enum.random(1..max(div(count, 2), 1)), else: 0
    classes = Enum.map(1..count, fn _ -> if :rand.uniform() < 0.15, do: :bad, else: :good end)
    classes |> sprinkle(shared, :shared) |> sprinkle(kills, :kill)
  end

  defp row_classes(:all_or_nothing, count) do
    good = List.duplicate(:good, count)

    case :rand.uniform(3) do
      1 -> sprinkle(good, 1, :kill)
      2 -> sprinkle(good, Enum.random(1..2), :bad)
      3 -> good
    end
  end

  defp sprinkle(classes, 0, _class), do: classes

  defp sprinkle(classes, n, class) do
    classes
    |> List.replace_at(:rand.uniform(length(classes)) - 1, class)
    |> sprinkle(n - 1, class)
  end

  defp shared_class, do: if(:rand.uniform() < 0.3, do: :bad, else: :good)

  defp own_input(:shared, _user), do: %{}
  defp own_input(value, user), do: %{value: value, owner_id: user.id}

  defp value(:good, key, version), do: "v#{version}:#{key}"
  defp value(:bad, key, _version), do: "bad:#{key}"
  defp value(:kill, key, _version), do: "kill:#{key}"

  defp wrap(value, true), do: {:resolve, EchoResolver, value}
  defp wrap(value, false), do: value

  defp resolved({:resolve, EchoResolver, value}), do: value
  defp resolved(value), do: value

  # What the row at `index` runs with now: its own input, or the shared one.
  defp current(ba, index) do
    case ba.inputs[index] do
      :shared -> ba.shared
      own -> resolved(own)
    end
  end

  defp class(value) do
    case value do
      "bad:" <> _ -> :bad
      "kill:" <> _ -> :kill
      _ -> :good
    end
  end

  # ── The pollers ─────────────────────────────────────────────────────────

  defp poller_name(i), do: :"stress_poller_#{i}"

  defp start_pollers! do
    children =
      for i <- 1..@pollers do
        Poller.child_spec(
          name: poller_name(i),
          poll_interval: @poll_interval,
          stale_after: @stale_after,
          max_running: @max_running,
          shutdown_grace: @shutdown_grace,
          staging_sweep_interval: nil
        )
      end

    start_supervised!(%{
      id: :stress_pollers,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one, max_restarts: 1_000]]}
    })
  end

  defp stop_pollers(_supervisor), do: stop_supervised!(:stress_pollers)

  # The runs a poller has going, as `{bulk_action_id, pid}`; none while it
  # is stopping or stopped.
  defp runs(name) do
    case Process.whereis(name) do
      nil -> []
      pid -> pid |> :sys.get_state(200) |> Map.fetch!(:running) |> Map.values()
    end
  catch
    :exit, _ -> []
  end

  # ── The driver ──────────────────────────────────────────────────────────

  defp drive(state) do
    state = state |> handle_messages() |> observe()

    cond do
      Enum.all?(state.bulk_actions, fn {_id, ba} -> ba.settled? end) ->
        state

      System.monotonic_time(:millisecond) > state.deadline ->
        timed_out(state)

      true ->
        Process.sleep(Enum.random(10..60))
        state |> chaos() |> drive()
    end
  end

  defp timed_out(state) do
    Enum.reduce(state.bulk_actions, state, fn
      {_id, %{settled?: true}}, state ->
        state

      {id, ba}, state ->
        record = reload(id)

        violation(
          state,
          "never reached a verdict before the timeout (nothing resumed it)",
          ba,
          "status #{record.status}, pass #{record.pass}, stalled_starts " <>
            "#{record.stalled_starts}, alive_at #{record.alive_at}"
        )
    end)
  end

  defp handle_messages(state) do
    receive do
      {:helper_done, _kind} -> handle_messages(%{state | helpers: state.helpers - 1})
      {:poller_up, name} -> handle_messages(put_in(state.pollers[name], :up))
    after
      0 -> state
    end
  end

  defp await_helpers(%{helpers: 0} = state), do: state

  defp await_helpers(state) do
    receive do
      {:helper_done, _kind} -> await_helpers(%{state | helpers: state.helpers - 1})
      {:poller_up, name} -> await_helpers(put_in(state.pollers[name], :up))
    after
      30_000 -> violation(state, "a chaos helper never finished", nil, "")
    end
  end

  # Holding a run until a retry goes first whenever it can: it is the one
  # chaos that has a run write in a pass it didn't start.
  defp chaos(state) do
    if random_run(state, &holdable?/1),
      do: suspend_run(state, :until_retry),
      else: random_chaos(state)
  end

  defp random_chaos(state) do
    case Enum.random(1..20) do
      n when n in 1..3 -> kill_run(state, :task)
      n when n in 4..5 -> kill_run(state, :ticker)
      6 -> restart_poller(state)
      7 -> suspend_run(state, :brief)
      n when n in 8..9 -> suspend_run(state, :until_retry)
      n when n in 10..12 -> hold_lock(state)
      _calm -> state
    end
  end

  defp up_pollers(state), do: for({name, :up} <- state.pollers, do: name)

  defp random_run(state, only \\ fn _ba -> true end) do
    frozen = frozen(state)

    runs =
      for name <- up_pollers(state),
          run <- runs(name),
          run.pid not in frozen,
          only.(state.bulk_actions[run.id]),
          do: run

    if runs == [], do: nil, else: Enum.random(runs)
  end

  # The runs held until a retry: no other chaos touches them, so each wakes
  # as it was.
  defp frozen(state), do: for({_id, ba} <- state.bulk_actions, {_helper, run} <- ba.held, do: run)

  # A bulk action whose shared input fails its rows: a retry corrects it,
  # and a run that outlived the retry would apply the old one.
  defp shared_failing?(ba), do: class(ba.shared) == :bad

  # One a run can be held in until a retry: the driver still retries it.
  defp holdable?(ba),
    do: shared_failing?(ba) and ba.held == [] and not ba.settled? and ba.retries < @max_retries

  defp kill_run(state, what) do
    with %{id: id, pid: pid} <- random_run(state),
         target when is_pid(target) <- if(what == :task, do: pid, else: ticker(pid)) do
      Process.exit(target, :kill)
      state |> count_chaos(what) |> disrupted(id, :crash)
    else
      _nothing -> state
    end
  end

  defp ticker(run) do
    case Process.info(run, :dictionary) do
      {:dictionary, dictionary} ->
        List.keyfind(dictionary, {Worker, :ticker}, 0, {nil, nil}) |> elem(1)

      nil ->
        nil
    end
  end

  # Stops a poller as a deploy would, through its shutdown, and starts it
  # again a moment later. A run it kills is marked `shutdown_stopped`, and
  # the design promises its next start counts no crash, so it counts no
  # disruption: a shutdown that cost a row a bump fails the test.
  defp restart_poller(state) do
    frozen = frozen(state)
    up = up_pollers(state)
    names = Enum.reject(up, fn name -> Enum.any?(runs(name), &(&1.pid in frozen)) end)

    # One poller always stays up.
    case names do
      _none_or_last when names == [] or length(up) < 2 ->
        state

      names ->
        name = Enum.random(names)
        pause = Enum.random(50..300)
        driver = self()

        helper(state, :restart, fn ->
          :ok = Supervisor.terminate_child(state.supervisor, name)
          Process.sleep(pause)
          {:ok, _pid} = Supervisor.restart_child(state.supervisor, name)
          send(driver, {:poller_up, name})
        end)
        |> put_in([:pollers, name], :restarting)
        |> count_chaos(:restart)
    end
  end

  # Suspends a run past `:stale_after`, so a poller starts the bulk action
  # again while the first run still lives. `:brief`, sometimes with its
  # ticker, for up to four times `:stale_after`. `:until_retry`, with its
  # ticker, until the driver has retried the bulk action, once another run
  # has finished it: the run then wakes in a pass it didn't start, as a run
  # on a paused node would. Only a run past its start, which has a ticker,
  # is held: one still starting would start the new pass on waking. A bulk action that isn't retried by then is woken
  # anyway.
  defp suspend_run(state, how) do
    only = if how == :until_retry, do: &holdable?/1, else: fn _ba -> true end

    with %{id: id, pid: pid} <- random_run(state, only),
         %{held: []} <- state.bulk_actions[id],
         ticker = List.wrap(ticker(pid)),
         true <- how == :brief or ticker != [] do
      pids = if how == :until_retry or :rand.uniform() < 0.5, do: [pid | ticker], else: [pid]
      pause = if how == :brief, do: Enum.random(@stale_after..(@stale_after * 4)), else: 5_000
      driver = self()

      # Only the process that suspended a process can resume it, so the
      # helper does both, and wakes them early when told.
      state =
        helper(state, :suspend, fn ->
          suspended = suspend_all(pids, how, id)
          send(driver, {:suspended, self()})

          receive do
            :resume -> :ok
          after
            pause -> :ok
          end

          Enum.each(suspended, &resume/1)
        end)

      assert_receive {:suspended, helper}, 5_000

      state =
        if how == :until_retry,
          do: put_in(state.bulk_actions[id].held, [{helper, pid}]),
          else: state

      crash = if length(pids) > 1, do: :crash, else: :overlap
      state |> count_chaos(how) |> disrupted(id, crash)
    else
      _nothing -> state
    end
  end

  # A run held until a retry is suspended outside any transaction of its own
  # or its ticker's, one holding the lock keeping every other run from
  # finishing the pass, and while rows are left for it to run.
  defp suspend_all(pids, :brief, _id), do: Enum.filter(pids, &suspend/1)

  defp suspend_all(pids, :until_retry, id, tries \\ 200) do
    suspended = Enum.filter(pids, &suspend/1)

    if tries > 0 and (Enum.any?(suspended, &checked_out?/1) or not open_rows?(id)) do
      Enum.each(suspended, &resume/1)
      Process.sleep(1)
      suspend_all(pids, :until_retry, id, tries - 1)
    else
      suspended
    end
  end

  # Holding a connection: Ecto keeps one checked out, as a transaction's is,
  # in the process dictionary.
  defp checked_out?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        Enum.any?(dictionary, &match?({{Ecto.Adapters.SQL, _pool}, _}, &1))

      nil ->
        false
    end
  end

  defp open_rows?(id) do
    %{rows: [[open]]} =
      Repo.query!(
        "SELECT count(*) FROM bulk_action_rows WHERE bulk_action_id = $1 " <>
          "AND status IN ('pending', 'resolved')",
        [Ecto.UUID.dump!(id)]
      )

    open > 0
  end

  defp suspend(pid) do
    :erlang.suspend_process(pid)
  catch
    :error, :badarg -> false
  end

  defp resume(pid) do
    :erlang.resume_process(pid)
  catch
    :error, :badarg -> :ok
  end

  # Holds a random unfinished bulk action's lock from a connection of its
  # own for a moment, if no one else holds it.
  defp hold_lock(state) do
    open = for {id, %{settled?: false}} <- state.bulk_actions, do: id

    case open do
      [] ->
        state

      ids ->
        id = Enum.random(ids)
        pause = Enum.random(20..300)

        state
        |> helper(:hold_lock, fn -> hold(id, pause) end)
        |> count_chaos(:hold_lock)
    end
  end

  defp hold(id, pause) do
    Repo.transaction(fn ->
      Repo.query!("SELECT 1 FROM bulk_actions WHERE id = $1 FOR NO KEY UPDATE SKIP LOCKED", [
        Ecto.UUID.dump!(id)
      ])

      Process.sleep(pause)
    end)
  end

  defp helper(state, kind, fun) do
    driver = self()

    spawn(fn ->
      try do
        fun.()
      after
        send(driver, {:helper_done, kind})
      end
    end)

    %{state | helpers: state.helpers + 1}
  end

  defp count_chaos(state, nil), do: state

  defp count_chaos(state, kind),
    do: update_in(state.chaos, &Map.update(&1, kind, 1, fn n -> n + 1 end))

  # Counts a disruption against the bulk action's current pass: a run that
  # died, or one suspended with its ticker, so that another run started the
  # bulk action over it (each can cost a stalled start). One that died, or
  # stopped stamping, while running a row alone (`isolating_row_id`) also
  # counts against that row: only such a row can have its `attempts` bumped
  # by the driver's chaos.
  defp disrupted(state, id, kind) do
    record = reload(id)
    increment = &Map.update(&1, &2, 1, fn n -> n + 1 end)
    state = update_in(state.bulk_actions[id].disruptions, &increment.(&1, record.pass))

    if kind == :crash and record.isolating_row_id,
      do:
        update_in(
          state.bulk_actions[id].row_disruptions,
          &increment.(&1, record.isolating_row_id)
        ),
      else: state
  end

  # ── Observing verdicts, retrying and abandoning ─────────────────────────

  defp observe(state) do
    ids = for {id, %{settled?: false}} <- state.bulk_actions, do: id

    BulkAction
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(&1.status in @terminal))
    |> Enum.reduce(state, &settle/2)
  end

  defp settle(record, state) do
    ba = state.bulk_actions[record.id]

    state =
      if MapSet.member?(ba.checked, record.pass),
        do: state,
        else: check_pass(state, record)

    ba = state.bulk_actions[record.id]
    ba = if ba.decision, do: ba, else: %{ba | decision: decide(ba, record)}
    act(state, record, ba)
  end

  # A run held until a retry gets one.
  defp decide(_ba, %{status: :completed}), do: :leave
  defp decide(%{retries: retries}, _record) when retries >= @max_retries, do: :leave
  defp decide(%{held: [_ | _]}, _record), do: {:retry, 0}
  defp decide(_ba, %{status: status}), do: decide(status, :rand.uniform())

  defp decide(:completed_with_errors, roll) when roll < 0.5, do: {:retry, 0}
  defp decide(:completed_with_errors, roll) when roll < 0.7, do: {:abandon, 0}
  defp decide(:failed, roll) when roll < 0.6, do: {:retry, 0}
  defp decide(_status, _roll), do: :leave

  # A retry or an abandon the lock refuses (one held by the driver's own
  # chaos) is tried again on the next tick, a few times.
  defp act(state, record, %{decision: :leave} = ba), do: leave(state, record, ba)
  defp act(state, record, %{decision: {_kind, 20}} = ba), do: leave(state, record, ba)

  defp act(state, record, %{decision: {:abandon, tries}} = ba) do
    case Core.abandon(record, scope: ba.scope) do
      {:ok, _cancelled} ->
        state
        |> count_chaos(:abandon)
        |> put_ba(record.id, %{ba | settled?: true, abandoned?: true, decision: nil, held: []})

      {:error, _refused} ->
        put_ba(state, record.id, %{ba | decision: {:abandon, tries + 1}})
    end
  end

  defp act(state, record, %{decision: {:retry, tries}} = ba) do
    version = ba.retries + 1
    failed = for row <- rows(record), row.status == :failed, do: row
    corrections = corrections(ba, failed, version)
    shared = shared_correction(ba, failed, version)

    case Retry.retry(record, retry_opts(ba, corrections, shared)) do
      {:ok, _retried} ->
        Enum.each(ba.held, fn {helper, _run} -> send(helper, :resume) end)

        inputs =
          Enum.reduce(corrections, ba.inputs, fn {_id, {index, value}}, inputs ->
            Map.put(inputs, index, value)
          end)

        state
        |> count_chaos(:retry)
        |> count_chaos(if ba.held != [], do: :woken_after_retry)
        |> put_ba(record.id, %{
          ba
          | inputs: inputs,
            shared: shared || ba.shared,
            retries: version,
            decision: nil,
            held: []
        })

      {:error, _refused} ->
        put_ba(state, record.id, %{ba | decision: {:retry, tries + 1}})
    end
  end

  # Some failed rows of their own get a corrected input of their own.
  defp corrections(ba, failed, version) do
    for row <- failed, ba.inputs[row.row_index] != :shared, :rand.uniform() < 0.7, into: %{} do
      key = "#{ba.tag}-r#{row.row_index}"
      value = wrap(value(:good, key, version), ba.resolving? and :rand.uniform() < 0.6)
      {row.id, {row.row_index, value}}
    end
  end

  # And, when a failed row runs with it, sometimes the shared input; always
  # for a bulk action with a run held until this retry.
  defp shared_correction(ba, failed, version) do
    if Enum.any?(failed, &(ba.inputs[&1.row_index] == :shared)) and
         (ba.held != [] or :rand.uniform() < 0.7),
       do: value(:good, "#{ba.tag}-shared", version)
  end

  defp retry_opts(ba, corrections, shared) do
    rows =
      Map.new(corrections, fn {id, {_index, value}} ->
        {id, %{input: own_input(value, ba.user)}}
      end)

    opts = [scope: ba.scope, rows: rows]
    if shared, do: [{:input, %{value: shared, owner_id: ba.user.id}} | opts], else: opts
  end

  defp leave(state, record, ba) do
    Enum.each(ba.held, fn {helper, _run} -> send(helper, :resume) end)
    put_ba(state, record.id, %{ba | settled?: true, decision: nil, held: []})
  end

  defp put_ba(state, id, ba), do: put_in(state.bulk_actions[id], ba)

  # ── Invariants of one pass, at its verdict ──────────────────────────────

  defp check_pass(state, record) do
    ba = state.bulk_actions[record.id]
    rows = rows(record)
    disruptions = Map.get(ba.disruptions, record.pass, 0)
    succeeded = Enum.count(rows, &(&1.status == :succeeded))

    # What each row that succeeded in this pass must have applied.
    expected =
      for row <- rows,
          row.status == :succeeded,
          not is_map_key(ba.expected, row.row_index),
          into: ba.expected,
          do: {row.row_index, current(ba, row.row_index)}

    state =
      state
      |> put_ba(record.id, %{
        ba
        | checked: MapSet.put(ba.checked, record.pass),
          expected: expected
      })
      |> check(
        record.rows_done == succeeded,
        "rows_done equals the :succeeded rows",
        ba,
        "pass #{record.pass}: rows_done #{record.rows_done}, #{succeeded} succeeded"
      )

    check_outcome(state, ba.mode, record, rows, ba, disruptions)
  end

  # Per row, only chaos can fail it, and only as `:crashed`: enough
  # stalled starts in a row to give up on it.
  defp check_outcome(state, :per_row, %{status: :failed} = record, _rows, ba, disruptions) do
    if record.result["reason"] == "crashed" and disruptions > max_setup_failures(),
      do: %{state | excused: state.excused + 1},
      else:
        violation(
          state,
          "a per-row verdict follows its rows",
          ba,
          "pass #{record.pass}: failed #{inspect(record.result)} (#{disruptions} disruptions)"
        )
  end

  defp check_outcome(state, :per_row, record, rows, ba, disruptions) do
    failed? = Enum.any?(rows, &(&1.status == :failed))
    expected = if failed?, do: :completed_with_errors, else: :completed

    state
    |> check(
      record.status == expected,
      "a per-row verdict follows its rows",
      ba,
      "pass #{record.pass}: #{record.status}, expected #{expected}"
    )
    |> then(&Enum.reduce(rows, &1, fn row, state -> check_row(state, row, ba, disruptions) end))
  end

  defp check_outcome(state, :all_or_nothing, record, rows, ba, disruptions) do
    {expected, excusable?} = expected_verdict(Enum.map(rows, &class(current(ba, &1.row_index))))
    got = if record.status == :failed, do: {:failed, record.result["reason"]}, else: record.status

    cond do
      got == expected ->
        check_all_or_nothing_rows(state, record, rows, ba)

      excusable? and got == {:failed, "crashed"} and disruptions >= max_stalled_starts() ->
        %{state | excused: state.excused + 1}

      true ->
        violation(
          state,
          "an all-or-nothing verdict follows its rows",
          ba,
          "pass #{record.pass}: #{inspect(got)}, expected #{inspect(expected)} " <>
            "(#{disruptions} disruptions)"
        )
    end
  end

  # The verdict its rows' inputs call for, and whether chaos alone could
  # fail it as crashed instead.
  defp expected_verdict(classes) do
    cond do
      :kill in classes -> {{:failed, "crashed"}, false}
      :bad in classes -> {{:failed, "atomic_chunk_rolled_back"}, true}
      true -> {:completed, true}
    end
  end

  # Its rows are untouched when it fails: every row :succeeded or none.
  defp check_all_or_nothing_rows(state, %{status: :completed} = record, rows, ba) do
    check(
      state,
      Enum.all?(rows, &(&1.status == :succeeded)),
      "no row left open under a verdict",
      ba,
      "pass #{record.pass}: #{inspect(Enum.frequencies_by(rows, & &1.status))}"
    )
  end

  defp check_all_or_nothing_rows(state, record, rows, ba) do
    check(
      state,
      not Enum.any?(rows, &(&1.status == :succeeded)),
      "a failed all-or-nothing bulk action applied nothing",
      ba,
      "pass #{record.pass}: #{inspect(Enum.frequencies_by(rows, & &1.status))}"
    )
  end

  # A row that ran in this pass ends as its input says. One the driver's
  # chaos interrupted at least `:max_row_attempts` times while it ran alone
  # can end crashed instead: from outside, a kill is a crash.
  defp check_row(state, row, ba, disruptions) do
    class = class(current(ba, row.row_index))
    crashed? = Enum.any?(row.error || [], &match?(%{error: %CrashedRowError{}}, &1))
    hits = Map.get(ba.row_disruptions, row.id, 0)
    excusable? = crashed? and class != :kill and hits >= max_row_attempts()

    cond do
      ends_as_input_says?(class, row, crashed?) ->
        state

      excusable? ->
        %{state | excused: state.excused + 1}

      true ->
        violation(
          state,
          "a row ends as its input says",
          ba,
          "row #{row.row_index} (#{row.id}), #{class}: #{row.status}, " <>
            "error #{inspect(row.error, limit: 5)} (#{hits} disruptions while it ran alone, " <>
            "#{disruptions} in the pass)"
        )
    end
  end

  defp ends_as_input_says?(:good, row, _crashed?), do: row.status == :succeeded

  defp ends_as_input_says?(:bad, row, crashed?),
    do: row.status == :failed and not crashed? and inspect(row.error) =~ "refused bad:"

  defp ends_as_input_says?(:kill, row, crashed?), do: row.status == :failed and crashed?

  # ── Invariants at the end ───────────────────────────────────────────────

  # No run, no ticker and no held lock outlives the bulk actions.
  defp check_nothing_running(state) do
    idle? = eventually(fn -> Enum.all?(Map.keys(state.pollers), &(runs(&1) == [])) end)

    state =
      check(
        state,
        idle?,
        "no run is left going",
        nil,
        inspect(Enum.flat_map(Map.keys(state.pollers), &runs/1))
      )

    leftovers =
      Enum.filter(Process.list(), fn pid ->
        case Process.info(pid, [:dictionary]) do
          [dictionary: dictionary] ->
            List.keymember?(dictionary, {Worker, :ticker}, 0) or
              match?({Liveness, _fun, _arity}, dictionary[:"$initial_call"])

          nil ->
            false
        end
      end)

    held =
      for {id, _ba} <- state.bulk_actions, not lockable?(id), do: id

    open = open_transactions()

    state
    |> check(leftovers == [], "no run or ticker process is left", nil, inspect(leftovers))
    |> check(held == [], "no bulk action lock is left held", nil, inspect(held))
    |> check(open == 0, "no transaction is left open", nil, "#{open} idle in transaction")
  end

  # Settles within a few seconds: a connection whose process was killed
  # is given back once the pool notices.
  defp open_transactions do
    Enum.reduce_while(1..100, 0, fn _try, _open ->
      case idle_in_transaction() do
        0 -> {:halt, 0}
        open -> Process.sleep(50) && {:cont, open}
      end
    end)
  end

  defp idle_in_transaction do
    %{rows: [[open]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
          "AND state LIKE 'idle in transaction%' AND pid <> pg_backend_pid()"
      )

    open
  end

  # Each pass reached one verdict, written in a transaction; an abandoned
  # bulk action's last pass one cancel besides.
  defp check_verdicts(state) do
    %{rows: rows} =
      Repo.query!("SELECT bulk_action_id, pass, status, in_transaction FROM stress_verdicts")

    outside = Enum.reject(rows, fn [_id, _pass, _status, in_transaction] -> in_transaction end)

    state =
      check(
        state,
        outside == [],
        "every verdict is written in a transaction",
        nil,
        inspect(outside)
      )

    verdicts =
      Enum.group_by(rows, fn [id, _, _, _] -> id && Ecto.UUID.load!(id) end, fn [
                                                                                  _,
                                                                                  pass,
                                                                                  status,
                                                                                  _
                                                                                ] ->
        {pass, status}
      end)

    Enum.reduce(state.bulk_actions, state, fn {id, ba}, state ->
      written = Map.get(verdicts, id, [])

      {cancels, finals} =
        Enum.split_with(written, fn {_pass, status} -> status == "cancelled" end)

      per_pass = Enum.frequencies_by(finals, &elem(&1, 0))
      expected = Map.new(ba.checked, &{&1, 1})

      state
      |> check(
        per_pass == expected,
        "every pass has exactly one verdict",
        ba,
        "verdicts per pass #{inspect(per_pass)}, passes seen #{inspect(MapSet.to_list(ba.checked))}"
      )
      |> check(
        length(cancels) == if(ba.abandoned?, do: 1, else: 0),
        "an abandon writes one cancel",
        ba,
        "#{length(cancels)} cancels, abandoned: #{ba.abandoned?}"
      )
    end)
  end

  # Every row was applied at most once, under the lock, by the pass it ran
  # in, with the input it had then; and every row :succeeded was applied.
  defp check_applications(state) do
    applied =
      Applied |> Ash.read!(authorize?: false) |> Enum.group_by(&{&1.owner_id, &1.row_index})

    Enum.reduce(state.bulk_actions, state, fn {id, ba}, state ->
      record = reload(id)
      rows = rows(record)
      succeeded = Enum.count(rows, &(&1.status == :succeeded))

      state =
        state
        |> check(
          record.rows_done == succeeded,
          "rows_done equals the :succeeded rows",
          ba,
          "at the end: rows_done #{record.rows_done}, #{succeeded} succeeded"
        )
        |> check_open_rows(record, rows, ba)

      Enum.reduce(
        rows,
        state,
        &check_applied(&2, &1, Map.get(applied, {ba.user.id, &1.row_index}, []), ba)
      )
    end)
  end

  defp check_open_rows(state, %{status: :cancelled}, _rows, _ba), do: state
  defp check_open_rows(state, %{mode: :all_or_nothing, status: :failed}, _rows, _ba), do: state

  defp check_open_rows(state, %{status: :failed, result: %{"reason" => "crashed"}}, _rows, _ba),
    do: state

  defp check_open_rows(state, record, rows, ba) do
    open = for row <- rows, row.status in [:pending, :resolved], do: "#{row.id} #{row.status}"

    check(
      state,
      open == [],
      "no row left open under a verdict",
      ba,
      "#{record.status}: #{inspect(open)}"
    )
  end

  defp check_applied(state, row, applications, ba) do
    key = "row #{row.row_index} (#{row.id})"
    expected = ba.expected[row.row_index]

    case {row.status, applications} do
      {:succeeded, [one]} ->
        state
        |> check(
          one.pass != -1,
          "a row is applied only under its bulk action's lock",
          ba,
          key
        )
        |> check(
          one.pass == row.pass,
          "a row is applied by the pass that ran it",
          ba,
          "#{key}: applied in pass #{one.pass}, row's pass #{row.pass}"
        )
        |> check(
          one.value == expected,
          "the applied data is the input the row had when it ran",
          ba,
          "#{key}: applied #{inspect(one.value)}, expected #{inspect(expected)}"
        )

      {:succeeded, []} ->
        violation(state, "every :succeeded row was applied", ba, key)

      {_status, []} ->
        state

      {status, many} ->
        violation(
          state,
          "a row is applied at most once, and only if it succeeded",
          ba,
          "#{key}, #{status}: applied " <>
            inspect(Enum.map(many, &{&1.pass, &1.value}))
        )
    end
  end

  # ── Recording verdicts ──────────────────────────────────────────────────

  # Every UPDATE that sets a bulk action's `finished_at` records the bulk
  # actions it finished in its own transaction, so one that rolls back leaves
  # no record. A retry's UPDATE sets it to NULL, and records none.
  defp attach_verdict_recorder do
    handler = "overlap-stress-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :test, :repo, :query],
      &__MODULE__.record_verdict/4,
      nil
    )

    handler
  end

  @doc false
  def record_verdict(
        _event,
        _measurements,
        %{source: "bulk_actions", query: "UPDATE" <> _ = query},
        _config
      ) do
    if query =~ ~s("finished_at" = ) do
      if Repo.in_transaction?() do
        Repo.query!(
          "INSERT INTO stress_verdicts (bulk_action_id, pass, status, in_transaction) " <>
            "SELECT id, pass, status, true FROM bulk_actions " <>
            "WHERE xmin = pg_current_xact_id()::xid AND finished_at IS NOT NULL"
        )
      else
        Repo.query!("INSERT INTO stress_verdicts (in_transaction) VALUES (false)")
      end
    end
  end

  def record_verdict(_event, _measurements, _metadata, _config), do: :ok

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp check(state, true, _invariant, _ba, _detail), do: state
  defp check(state, false, invariant, ba, detail), do: violation(state, invariant, ba, detail)

  defp violation(state, invariant, ba, detail) do
    who =
      if ba,
        do: "bulk action #{ba.index} (#{bulk_action_id(state, ba)}, #{ba.mode})",
        else: "system"

    %{state | violations: ["#{invariant}: #{who}: #{detail}" | state.violations]}
  end

  defp bulk_action_id(state, ba) do
    Enum.find_value(state.bulk_actions, fn {id, other} -> if other.index == ba.index, do: id end)
  end

  defp reload(id), do: Ash.get!(BulkAction, id, authorize?: false)

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp max_row_attempts, do: Core.config(:max_row_attempts, 2)
  defp max_stalled_starts, do: Core.config(:max_stalled_starts, 3)
  defp max_setup_failures, do: Core.config(:max_setup_failures, 3)

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

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  defp summary(report, elapsed) do
    rows = report.bulk_actions |> Enum.map(fn {_id, ba} -> map_size(ba.inputs) end) |> Enum.sum()

    "  #{map_size(report.bulk_actions)} bulk actions, #{rows} rows, " <>
      "#{Float.round(elapsed / 1_000_000, 1)}s; outcomes #{inspect(report.outcomes)}; " <>
      "chaos #{inspect(report.chaos)}; excused #{report.excused}; " <>
      "#{length(report.violations)} violations"
  end

  # Every user an iteration made has an email ending in its tag.
  defp cleanup(tag) do
    users = "SELECT id FROM users WHERE email LIKE '%.' || $1 || '@example.test'"
    Repo.query!("DELETE FROM bulk_actions WHERE user_id IN (#{users})", [tag])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [tag])
  end
end
