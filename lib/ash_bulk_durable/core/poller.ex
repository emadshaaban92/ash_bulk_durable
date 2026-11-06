defmodule AshBulkDurable.Core.Poller do
  @moduledoc """
  Starts the runs of bulk actions: one per node, it finds the bulk actions
  that need a run and runs each in a task
  (`AshBulkDurable.Core.Worker.run/2`). The `bulk_actions` table is the only
  record of what needs running.

  Add it last to the host's supervision tree: after the repo, anything that
  migrates it (such as an `Ecto.Migrator` child), and whatever a run
  broadcasts through (the PubSub and the endpoint). A supervisor stops its
  children in reverse order, so the poller then stops first, and the runs it
  lets finish on shutdown can still write and broadcast:

      children = [
        MyApp.Repo,
        {Ecto.Migrator, repos: [MyApp.Repo]},
        MyApp.PubSub,
        MyAppWeb.Endpoint,
        AshBulkDurable.Core.Poller
      ]

  ## What it starts

  Every `:poll_interval`, and when nudged (`nudge/0`), it fills its free
  slots of `:max_running` with the oldest bulk actions that are `:queued`, or
  `:running` with a liveness hint (`alive_at`, see
  `AshBulkDurable.Core.Liveness`) older than `:stale_after` on the
  database's clock: a run whose node died. It skips those it runs itself.
  Each runs as `Worker.run(id, if_stale_after: stale_after)`, so a bulk action
  another node started or stamped since the poll read it is left alone.

  Nothing here keeps two nodes from starting the same bulk action, and
  nothing needs to: the bulk action lock makes overlapping runs harmless
  (see `AshBulkDurable.Core.Worker`). The poller's only job is that every
  bulk action still queued or running eventually has a run.

  A run that returns or crashes frees its slot, and the poller fills it
  straight away. A crash is logged; the bulk action stays `:running`, its
  hint as the run's start stamped it, and is started again once that is
  stale. A bulk action whose run keeps crashing is therefore started again
  every `:stale_after`. A run that returns `:busy` frees its slot until the
  next poll instead: another transaction took the bulk action's lock between
  the poll and the run, and filling now would start it again at once.

  The poll skips a bulk action another transaction holds right now, such as
  one inside a long all-or-nothing chunk on another node, which stamps
  nothing while it runs and so reads as stale; picked oldest first, such
  bulk actions would take every slot and starve the newer ones.

  Each running bulk action takes one connection, up to
  `:phase1_concurrency` more while phase 1 resolves its rows, and one more
  for its ticker's stamp (`AshBulkDurable.Core.Liveness`), held briefly each
  `:alive_interval`: size the repo's pool for `:max_running` times
  `:phase1_concurrency + 2`.

  ## Without a poller

  Bulk actions stay `:queued` and nothing fails. A bulk action submitted or
  retried on a node with no poller under the default name logs a warning,
  once per node. Set `warn_without_poller: false` in the `ash_bulk_durable`
  config where that is meant: a node that only serves pages while other
  nodes run bulk actions, or tests, which run them with
  `AshBulkDurable.Core.Worker.run_now/1` and `AshBulkDurable.Core.Worker.drain/0`.

  ## Staged files

  Every `:staging_sweep_interval` it runs the staged-file sweep
  (`AshBulkDurable.Core.PurgeStaleStaging.sweep/0`) in a task. The first
  lands at a random time within the first hour, so nodes restarted together
  don't all sweep at once, and a node restarted more often than the interval
  still sweeps. The sweep holds no lock: nodes sweeping at once only delete
  the same keys.

  ## Options

  Each defaults to the `ash_bulk_durable` config key of the same name:

    * `:poll_interval` — milliseconds between polls, `5_000` by default.
    * `:max_running` — bulk actions this node runs at once, `2` by default.
    * `:stale_after` — milliseconds after which a `:running` bulk action's
      liveness hint is stale, 2 minutes by default. Keep it well above
      `:alive_interval` (30 seconds by default). Too short only wastes work
      on duplicate runs; too long only delays resuming after a node dies.
    * `:staging_sweep_interval` — milliseconds between staged-file sweeps, a
      day by default; `nil` runs none.
    * `:shutdown_grace` — milliseconds a run still going at shutdown is given
      to finish, `20_000` by default. The child spec's `:shutdown` is set
      above it.
    * `:name` — the process name, `AshBulkDurable.Core.Poller` by default.
      `nudge/0` reaches only the poller under the default name.

  ## Shutdown

  It stops starting runs, then gives the runs still going `:shutdown_grace`
  to finish, and kills those that haven't. A killed run's transaction rolls
  back, and its rows resume on another node, or this one once restarted,
  when its hint goes stale.

  A killed run didn't crash, so the poller then sets `shutdown_stopped` on
  its bulk action, and the next start doesn't count it as stalled (see
  "Crashes" in `AshBulkDurable.Core.Worker`). It takes the bulk action's
  lock to do so, waiting at most 2 seconds for the killed run's transaction
  to let go of it: the one wait on the lock anywhere. A node stopped without
  this shutdown (out of memory, `kill -9`) counts as a crash.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.{BulkActionLock, Liveness, PurgeStaleStaging, Worker}

  @poll_interval :timer.seconds(5)
  @max_running 2
  @stale_after :timer.minutes(2)
  @staging_sweep_interval :timer.hours(24)
  @shutdown_grace :timer.seconds(20)
  @shutdown_lock_wait :timer.seconds(2)

  def child_spec(opts) do
    grace = option(opts, :shutdown_grace, @shutdown_grace)
    marks = option(opts, :max_running, @max_running) * @shutdown_lock_wait

    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: grace + marks + :timer.seconds(5)
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Asks this node's poller, the one under the default name, to fill its free
  slots now rather than at its next poll. `AshBulkDurable.Core.create/4` and
  the retries call it once they return `{:ok, _}`; a host that queues bulk
  actions some other way can too. With none running, logs a warning, once
  per node, unless the `:warn_without_poller` config is `false`.
  """
  def nudge do
    case Process.whereis(__MODULE__) do
      nil -> warn_without_poller()
      pid -> send(pid, :nudge)
    end

    :ok
  end

  # A result still inside a caller's transaction may roll back, and a run
  # started now would find nothing committed: the next poll starts it.
  @doc false
  def nudge_after({:ok, _} = result) do
    unless in_transaction?(), do: nudge()
    result
  end

  def nudge_after(result), do: result

  defp in_transaction? do
    Core.config(:bulk_action_resource)
    |> AshPostgres.DataLayer.Info.repo(:mutate)
    |> then(& &1.in_transaction?())
  end

  defp warn_without_poller do
    key = {__MODULE__, :warned}

    if Core.config(:warn_without_poller, true) and not :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "ash_bulk_durable: a bulk action was queued, but no AshBulkDurable.Core.Poller " <>
          "runs on this node, so it stays :queued unless another node runs one. Add the " <>
          "poller to the supervision tree, or set `warn_without_poller: false` on nodes " <>
          "that leave bulk actions to others."
      )
    end
  end

  @doc "The ids of the bulk actions this poller is running."
  def running(server \\ __MODULE__), do: GenServer.call(server, :running)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, tasks} = Task.Supervisor.start_link()

    state = %{
      tasks: tasks,
      running: %{},
      stopping?: false,
      poll_interval: option(opts, :poll_interval, @poll_interval),
      max_running: option(opts, :max_running, @max_running),
      stale_after: option(opts, :stale_after, @stale_after),
      sweep_interval: option(opts, :staging_sweep_interval, @staging_sweep_interval),
      shutdown_grace: option(opts, :shutdown_grace, @shutdown_grace),
      poll_timer: nil,
      sweep_timer: nil
    }

    {:ok, state |> schedule_poll() |> schedule_first_sweep()}
  end

  defp option(opts, key, default) do
    Keyword.get_lazy(opts, key, fn -> Core.config(key, default) end)
  end

  @impl true
  def handle_call(:running, _from, state),
    do: {:reply, Enum.map(state.running, fn {_ref, %{id: id}} -> id end), state}

  @impl true
  def handle_info(:poll, state), do: {:noreply, state |> fill() |> schedule_poll()}

  # Fills without moving the timer, so a burst of submits starts no more
  # than there are slots.
  def handle_info(:nudge, state), do: {:noreply, fill(state)}

  def handle_info(:sweep, state) do
    Task.Supervisor.start_child(state.tasks, &sweep/0)
    {:noreply, schedule_sweep(state, state.sweep_interval)}
  end

  # A run returned: its slot is free now. One that found the bulk action
  # locked (`:busy`) leaves it for the next poll: the bulk action still reads
  # as startable, and filling now would start it again at once, as often as
  # its lock holder's chunk takes.
  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | running: Map.delete(state.running, ref)}
    {:noreply, if(result == :busy, do: state, else: fill(state))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {%{id: id}, running} = Map.pop(state.running, ref)
    Logger.error("ash_bulk_durable: bulk action #{id} crashed: #{Exception.format_exit(reason)}")
    {:noreply, fill(%{state | running: running})}
  end

  def handle_info({:EXIT, pid, reason}, %{tasks: pid} = state), do: {:stop, reason, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state = stop_starting(state)
    deadline = System.monotonic_time(:millisecond) + state.shutdown_grace
    state = await_runs(state, deadline)

    runs = Map.values(state.running)

    Enum.each(state.running, fn {ref, run} ->
      Process.demonitor(ref, [:flush])

      Logger.warning(
        "ash_bulk_durable: bulk action #{run.id} was still running at shutdown; " <>
          "it resumes once its liveness hint goes stale"
      )
    end)

    # All die at once, then each is marked, waiting at most
    # `@shutdown_lock_wait` for its lock: the child spec allows for both.
    kill_all(runs)
    Enum.each(runs, &mark_shutdown_stopped(&1.id))
  end

  defp kill_all(runs) do
    deadline = System.monotonic_time(:millisecond) + @shutdown_lock_wait

    runs
    |> Enum.map(fn %{pid: pid} ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      {ref, pid}
    end)
    |> Enum.each(fn {ref, pid} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        remaining -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  # The killed run's transaction rolls back as its connection notices, so
  # this waits for the lock, briefly: a run of a bulk action that's still
  # running elsewhere may hold it longer, and is left to count.
  defp mark_shutdown_stopped(id) do
    Ash.transaction([Core.config(:bulk_action_resource)], fn ->
      case BulkActionLock.lock(id, [:queued, :running], wait: @shutdown_lock_wait) do
        {:ok, locked} ->
          {:ok, _marked, _notifications} =
            Ash.update(locked, %{shutdown_stopped: true},
              action: :count_crashes,
              authorize?: false,
              return_notifications?: true
            )

        :none ->
          :ok
      end
    end)
    |> case do
      {:ok, _marked} -> :ok
      {:error, error} -> warn_unmarked(id, error)
    end
  rescue
    exception -> warn_unmarked(id, exception)
  end

  # `Ash.transaction/2` returns a lock timeout as an error rather than raising.
  defp warn_unmarked(id, error) do
    message = if is_exception(error), do: Exception.message(error), else: inspect(error)

    Logger.warning(
      "ash_bulk_durable: bulk action #{id} was stopped by shutdown, but couldn't be " <>
        "marked so; its next start counts it as stalled: #{message}"
    )
  end

  defp await_runs(state, _deadline) when map_size(state.running) == 0, do: state

  defp await_runs(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {ref, _result} when is_map_key(state.running, ref) ->
        Process.demonitor(ref, [:flush])
        await_runs(%{state | running: Map.delete(state.running, ref)}, deadline)

      {:DOWN, ref, :process, _pid, _reason} when is_map_key(state.running, ref) ->
        await_runs(%{state | running: Map.delete(state.running, ref)}, deadline)
    after
      remaining -> state
    end
  end

  defp fill(%{stopping?: true} = state), do: state

  defp fill(state) do
    case state.max_running - map_size(state.running) do
      free when free > 0 -> state |> candidates(free) |> Enum.reduce(state, &start_run/2)
      _full -> state
    end
  end

  # One query on the partial index the bulk action resource declares. It
  # skips the bulk actions another transaction holds right now, such as a
  # long all-or-nothing chunk on another node, which stamps nothing while it
  # runs: picked oldest first, they would take every slot on every poll and
  # starve the newer ones. Its locks only filter, and go at once with its
  # short transaction. A poll that fails is logged and starts nothing; the
  # next one tries again.
  defp candidates(state, free) do
    running = Enum.map(state.running, fn {_ref, %{id: id}} -> id end)
    resource = Core.config(:bulk_action_resource)

    {:ok, ids} =
      Ash.transaction([resource], fn ->
        resource
        |> Ash.Query.filter(fragment("? IN ('queued', 'running')", status) and id not in ^running)
        |> Ash.Query.do_filter(Liveness.startable(state.stale_after))
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.Query.limit(free)
        |> Ash.Query.select([:id])
        |> Ash.Query.lock("FOR NO KEY UPDATE SKIP LOCKED")
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
      end)

    ids
  rescue
    exception ->
      Logger.error("ash_bulk_durable: polling for bulk actions: #{Exception.message(exception)}")
      []
  end

  defp start_run(id, state) do
    stale_after = state.stale_after

    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        Worker.run(id, if_stale_after: stale_after)
      end)

    %{state | running: Map.put(state.running, task.ref, %{id: id, pid: task.pid})}
  end

  defp sweep do
    PurgeStaleStaging.sweep()
  rescue
    exception ->
      Logger.error("ash_bulk_durable: staged-file sweep failed: #{Exception.message(exception)}")
  end

  defp stop_starting(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    if state.sweep_timer, do: Process.cancel_timer(state.sweep_timer)
    %{state | stopping?: true, poll_timer: nil, sweep_timer: nil}
  end

  defp schedule_poll(state),
    do: %{state | poll_timer: Process.send_after(self(), :poll, state.poll_interval)}

  defp schedule_first_sweep(%{sweep_interval: nil} = state), do: state

  defp schedule_first_sweep(state),
    do: schedule_sweep(state, :rand.uniform(min(state.sweep_interval, :timer.hours(1))))

  defp schedule_sweep(%{sweep_interval: nil} = state, _after), do: state

  defp schedule_sweep(state, after_ms),
    do: %{state | sweep_timer: Process.send_after(self(), :sweep, after_ms)}
end
