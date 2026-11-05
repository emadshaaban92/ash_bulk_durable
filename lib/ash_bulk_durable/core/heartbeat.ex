defmodule AshBulkDurable.Core.Heartbeat do
  @moduledoc """
  How a dead node's run is told from a slow one. A node that dies leaves its
  job `:executing` for good, and row progress can't show it: resolving writes
  only rows, and an all-or-nothing run commits nothing until its one
  transaction does. So the worker says it is alive, on the Oban job's `meta`:
  a transaction holds the bulk action's row locked, and nothing locks the job's
  while it runs.

  A job silent for `:worker_lost_after` (five minutes) has lost its worker,
  however long its rows take. It beats ten times in that span, so a few missed
  beats (a busy database) lose nothing.
  """
  require Logger

  @worker_lost_after :timer.minutes(5)

  @doc "Runs `fun`, the job beating for as long as it does."
  def beating(%Oban.Job{} = job, fun) do
    beat = Task.async(fn -> beat(job, div(worker_lost_after(), 10)) end)

    try do
      fun.()
    after
      send(beat.pid, :stop)
      Task.yield(beat, :timer.seconds(5)) || Task.shutdown(beat, :brutal_kill)
    end
  end

  @doc "True when `job`, `:executing`, has said nothing for `:worker_lost_after`."
  def silent?(%Oban.Job{attempted_at: attempted_at, meta: meta}) do
    picked_up = DateTime.to_unix(attempted_at, :millisecond)
    last_heard = max(picked_up, Map.get(meta, "heartbeat_at", picked_up))

    System.system_time(:millisecond) - last_heard > worker_lost_after()
  end

  defp worker_lost_after,
    do: AshBulkDurable.Core.config(:worker_lost_after, @worker_lost_after)

  defp beat(job, interval) do
    receive do
      :stop -> :ok
    after
      interval ->
        record(job)
        beat(job, interval)
    end
  end

  # Linked to the worker, so a beat that raised would take the run with it.
  defp record(job) do
    now = System.system_time(:millisecond)

    case Oban.update_job(job, %{meta: Map.put(job.meta, "heartbeat_at", now)}) do
      {:ok, _job} -> :ok
      {:error, reason} -> missed(job, reason)
    end
  rescue
    exception -> missed(job, exception)
  end

  defp missed(job, reason) do
    Logger.warning("Bulk action job #{job.id} missed a heartbeat: #{inspect(reason)}")
  end
end
