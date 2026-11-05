defmodule AshBulkDurable.Core.Poller do
  @moduledoc """
  Runs bulk actions: one per node, it claims queued bulk actions from the
  `bulk_actions` table (`AshBulkDurable.Core.Lease`) and runs each in a task
  (`AshBulkDurable.Core.Worker.run/1`). The table is the queue; there is no
  job to keep in step with the bulk action.

  Add it to the host's supervision tree after the repo, and after anything
  that migrates it (such as an `Ecto.Migrator` child):

      children = [
        MyApp.Repo,
        {Ecto.Migrator, repos: [MyApp.Repo]},
        AshBulkDurable.Core.Poller,
        MyAppWeb.Endpoint
      ]

  Without one, bulk actions stay `:queued` and nothing fails. So a bulk
  action submitted or retried on a node with no poller under its default
  name logs a warning, once per node. Set `warn_without_poller: false` in the
  `ash_bulk_durable` config where that is meant: a node that only serves
  pages while other nodes run bulk actions, or tests, which run them with
  `AshBulkDurable.Core.Worker.drain/0`.

  Every `:poll_interval` it fails the bulk actions that ran out of attempts
  (`Lease.fail_exhausted/0`) and claims as many as it has free slots of
  `:max_running`. It also claims straight away when one of its runs ends,
  and when a bulk action is submitted or retried on its node (`nudge/0`),
  so neither waits for the next poll. Every `:staging_sweep_interval` it runs the staged-file
  sweep (`AshBulkDurable.Core.PurgeStaleStaging.sweep/0`). The sweep holds
  no lock and no transaction: it is idempotent, so nodes sweeping at once
  only delete the same keys.

  Options, each defaulting to the `ash_bulk_durable` config key of the same
  name:

    * `:poll_interval` — milliseconds between polls, `5_000` by default.
    * `:max_running` — bulk actions this node runs at once, `2` by default.
    * `:staging_sweep_interval` — milliseconds between staged-file sweeps,
      a day by default; `nil` runs none. The first runs within the first
      hour, so a node restarted more often than the interval still sweeps.
    * `:name` — the process name, `AshBulkDurable.Core.Poller` by default.

  ## Shutdown

  On shutdown, or `drain/1`, it cancels its timers and claims nothing more,
  so no bulk action is claimed only to be dropped. On shutdown, a run still
  going is stopped (its transaction rolls back) and its lease released with
  its attempt given back, so another node resumes it from its rows at its
  next poll, and a rolling deploy uses up no attempts. Only
  `:max_attempts` shutdowns are given back, so a bulk action whose nodes
  keep being stopped still reaches the ceiling. A run that already ended
  released its own lease, and is left as it left it.

  A claim that fails on a database error is logged and claims nothing; the
  next poll tries again.
  """
  use GenServer

  require Logger

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.{Lease, PurgeStaleStaging, Worker}

  @poll_interval :timer.seconds(5)
  @max_running 2
  @staging_sweep_interval :timer.hours(24)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Stops claiming and cancels the timers; runs already going carry on."
  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain)

  @doc "Polls now, as the timer would. Returns once the claim is made."
  def poll(server \\ __MODULE__), do: GenServer.call(server, :poll)

  @doc """
  Asks this node's poller, the one under the default name, to claim now
  rather than at its next poll. `AshBulkDurable.Core.create/4` and retries
  call it once their transaction returns; a host that queues bulk actions
  some other way can too. With none running, logs a warning, once per node, unless the
  `:warn_without_poller` config is `false`.
  """
  def nudge do
    case Process.whereis(__MODULE__) do
      nil -> warn_without_poller()
      pid -> send(pid, :nudge)
    end

    :ok
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
      draining: false,
      poll_interval: option(opts, :poll_interval, @poll_interval),
      max_running: option(opts, :max_running, @max_running),
      sweep_interval: option(opts, :staging_sweep_interval, @staging_sweep_interval),
      poll_timer: nil,
      sweep_timer: nil
    }

    {:ok, state |> schedule_poll() |> schedule_first_sweep()}
  end

  defp option(opts, key, default) do
    Keyword.get_lazy(opts, key, fn -> Core.config(key, default) end)
  end

  @impl true
  def handle_call(:drain, _from, state), do: {:reply, :ok, stop_claiming(state)}

  def handle_call(:poll, _from, state), do: {:reply, :ok, claim(state)}

  def handle_call(:running, _from, state),
    do: {:reply, Enum.map(state.running, fn {_ref, %{id: id}} -> id end), state}

  @impl true
  # A `:poll` already in the mailbox when draining began claims nothing.
  def handle_info(:poll, %{draining: true} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    {:noreply, state |> claim() |> schedule_poll()}
  end

  # Claims without moving the timer: a burst of submits claims no faster
  # than they arrive. Draining, `claim/1` claims nothing.
  def handle_info(:nudge, state), do: {:noreply, claim(state)}

  def handle_info(:sweep, %{draining: true} = state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    Task.Supervisor.start_child(state.tasks, &sweep/0)
    {:noreply, schedule_sweep(state, state.sweep_interval)}
  end

  # A run returned: its slot is free now.
  def handle_info({ref, _result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, claim(%{state | running: Map.delete(state.running, ref)})}
  end

  # A run crashed. One that raised, exited or threw released its lease
  # (with a backoff); one its lease renewer stopped had lost the claim.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.running, ref) do
    {%{id: id}, running} = Map.pop(state.running, ref)
    Logger.error("ash_bulk_durable: bulk action #{id} crashed: #{Exception.format_exit(reason)}")
    {:noreply, claim(%{state | running: running})}
  end

  def handle_info({:EXIT, pid, reason}, %{tasks: pid} = state), do: {:stop, reason, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_claiming(state)

    Enum.each(state.running, &stop_run(state.tasks, &1))
  end

  # A run that already ended, but whose message this poller never handled,
  # gave its lease back itself, perhaps with a backoff not to undo here.
  defp stop_run(tasks, {_ref, run}) do
    if Process.alive?(run.pid) do
      terminate_run(tasks, run.pid)
      Lease.release(run.id, run.token, refund: true)
    end
  end

  # The task supervisor may already be gone; the leases must still go back.
  defp terminate_run(tasks, pid) do
    Task.Supervisor.terminate_child(tasks, pid)
  catch
    :exit, _reason -> Process.exit(pid, :kill)
  end

  defp claim(%{draining: true} = state), do: state

  defp claim(state) do
    fail_exhausted()

    case state.max_running - map_size(state.running) do
      free when free > 0 ->
        free
        |> Lease.claim()
        |> Enum.reduce(state, &start_run/2)

      _full ->
        state
    end
  end

  defp start_run(bulk_action, state) do
    task = Task.Supervisor.async_nolink(state.tasks, fn -> Worker.run(bulk_action) end)
    run = %{id: bulk_action.id, token: bulk_action.claim_token, pid: task.pid}
    %{state | running: Map.put(state.running, task.ref, run)}
  end

  defp fail_exhausted do
    Lease.fail_exhausted()
  rescue
    exception ->
      Logger.error(
        "ash_bulk_durable: failing exhausted bulk actions: #{Exception.message(exception)}"
      )
  end

  defp sweep do
    PurgeStaleStaging.sweep()
  rescue
    exception ->
      Logger.error("ash_bulk_durable: staged-file sweep failed: #{Exception.message(exception)}")
  end

  defp stop_claiming(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    if state.sweep_timer, do: Process.cancel_timer(state.sweep_timer)
    %{state | draining: true, poll_timer: nil, sweep_timer: nil}
  end

  defp schedule_poll(state),
    do: %{state | poll_timer: Process.send_after(self(), :poll, state.poll_interval)}

  # Spread over the first hour, so nodes restarted together don't sweep
  # together, and one restarted more often than the interval still sweeps.
  defp schedule_first_sweep(%{sweep_interval: nil} = state), do: state

  defp schedule_first_sweep(state),
    do: schedule_sweep(state, :rand.uniform(min(state.sweep_interval, :timer.hours(1))))

  defp schedule_sweep(%{sweep_interval: nil} = state, _after), do: state

  defp schedule_sweep(state, after_ms),
    do: %{state | sweep_timer: Process.send_after(self(), :sweep, after_ms)}
end
