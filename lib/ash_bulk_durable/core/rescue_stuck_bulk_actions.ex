defmodule AshBulkDurable.Core.RescueStuckBulkActions do
  @moduledoc """
  Cron backstop for stuck `:queued` / `:running` `BulkAction`s.

  `max_attempts: 3` means three worker crashes in a row drop the
  Oban job into `:discarded` while the bulk action still looks `:running`. The
  partial unique index then locks the user out of submitting a new
  bulk action forever. The same lockout happens if Oban prunes the job row for
  any other reason, and if the node running the job dies: nothing moves
  that job off `:executing`, so its silence is what gives it away
  (`AshBulkDurable.Core.Heartbeat`).

  Two mechanisms close that hole, and **both go through this module** so
  the `worker_lost` detection and the terminal flip live in exactly one
  place:

    * **Mount-time check (lazy).** The `/bulk` screen calls
      `rescue_if_stuck/1` when it reattaches a logged-in user to their
      in-flight bulk action — instant unlock for the common case.
    * **Cron backstop (eager).** This worker's `perform/1` sweeps every
      in-flight bulk action on a schedule so the locked-out state is impossible
      even when the user never reopens `/bulk`.

  ## False-positive guards

  `rescue_if_stuck/1` only considers `:queued` / `:running` bulk actions — the
  statuses that claim a live worker. A `:completed_with_errors` bulk action also
  holds the one-unresolved slot and is reattached at mount, but its Oban
  job is *legitimately* terminal (the worker finished), so it must never
  look "stuck"; it's released by the user retrying or abandoning, not by
  a rescue.

  For rescuable bulk actions, `worker_lost?/1` only fires on a *terminal* Oban
  job state (`:completed`, `:discarded`, `:cancelled`), a missing job
  row, or an `:executing` job gone silent. A job that's `:available` (queued,
  not yet picked up), `:executing` and beating, or `:retryable` (between
  attempts) is healthy and left alone — so a momentary insert/pickup race, a
  slow run or a mid-retry crash can't flip a live bulk action to `:failed`.

  Even those guards can race: between `worker_lost?/1` reading the Oban
  job and `mark_worker_lost/1` writing `:failed`, a legitimately
  retrying worker could pick the job back up and start driving the bulk action
  again. `mark_worker_lost/1` closes that TOCTOU window by filtering
  the UPDATE on `status in [:queued, :running]` — if the row has
  advanced past that set (a healthy worker won the race), the UPDATE
  affects zero rows and the bulk action is left untouched.
  """
  use Oban.Worker, queue: :default

  require Ash.Query
  import Ash.Expr

  alias AshBulkDurable.Core.Heartbeat

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Enum.each(in_flight_bulk_actions(), &rescue_if_stuck/1)
    :ok
  end

  @doc """
  Flips `bulk_action` to `:failed`/`worker_lost` if its worker is provably gone,
  otherwise returns it untouched. The single entry point shared by the
  mount-time check and the cron sweep.

  Only `:queued` / `:running` bulk actions are rescue candidates; any other
  status (notably a parked `:completed_with_errors` bulk action, whose Oban job
  is legitimately terminal) passes through untouched.
  """
  def rescue_if_stuck(%{status: status} = bulk_action) when status in [:queued, :running] do
    if worker_lost?(bulk_action), do: mark_worker_lost(bulk_action), else: bulk_action
  end

  def rescue_if_stuck(bulk_action), do: bulk_action

  @doc """
  True when the bulk action's Oban job is in a terminal state, its row is gone,
  or it is `:executing` and silent — meaning no worker is (or will be) driving
  the bulk action. A nil `oban_job_id` (job never recorded) also counts as lost.
  """
  def worker_lost?(%{oban_job_id: nil}), do: true

  def worker_lost?(%{oban_job_id: job_id}) do
    case Oban.config().repo.get(Oban.Job, job_id) do
      nil -> true
      %Oban.Job{state: "executing"} = job -> Heartbeat.silent?(job)
      %Oban.Job{state: state} -> state in ~w(completed discarded cancelled)
    end
  end

  @doc """
  Marks `bulk_action` `:failed` with the canonical `worker_lost` reason via the
  same `:mark_finished` action the worker uses for every terminal flip.

  The UPDATE is guarded by a `status in [:queued, :running]` filter so
  a stale `worker_lost?/1` check can't clobber a bulk action that a healthy
  worker has since moved past those statuses. When the guard rejects
  the update (zero rows affected, surfaced as `StaleRecord`), the bulk action
  is returned untouched — the race was lost, which is the correct
  outcome.

  The job is cancelled with it: a dead node's would stay `:executing` for
  good, and a worker that only went silent must not write past the verdict.
  """
  def mark_worker_lost(bulk_action) do
    changeset =
      bulk_action
      |> Ash.Changeset.for_update(
        :mark_finished,
        %{result: {:failed, %{reason: :worker_lost}}},
        authorize?: false
      )
      |> Ash.Changeset.filter(expr(status in [:queued, :running]))

    case Ash.update(changeset) do
      {:ok, updated} ->
        cancel_job(updated)
        updated

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
          bulk_action
        else
          raise error
        end
    end
  end

  defp cancel_job(%{oban_job_id: nil}), do: :ok
  defp cancel_job(%{oban_job_id: job_id}), do: Oban.cancel_job(job_id)

  defp in_flight_bulk_actions do
    case AshBulkDurable.Core.config(:bulk_action_resource) do
      nil ->
        []

      bulk_action_resource ->
        bulk_action_resource
        |> Ash.Query.filter(status in [:queued, :running])
        |> Ash.read!(authorize?: false)
    end
  end
end
