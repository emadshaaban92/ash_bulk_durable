defmodule AshBulkDurable.Core.Changes.EnqueueWorker do
  @moduledoc """
  After-action change on `BulkAction.:create` (and `:enqueue_retry`) that
  inserts an `AshBulkDurable.Core.Worker` Oban job for the bulk action and writes
  the resulting `oban_job_id` back onto the bulk action via `:set_oban_job_id`.

  Composes inside the action's transaction: if `Oban.insert/2` fails,
  the bulk action insert (and any prior after_action writes like `PersistRows`)
  rolls back. The doc calls this out as the "no half-run bulk actions"
  guarantee.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, bulk_action ->
      enqueue(bulk_action)
    end)
  end

  defp enqueue(bulk_action) do
    queue = AshBulkDurable.Core.config(:queue, :bulk_actions)
    worker = AshBulkDurable.Core.config(:worker_module, AshBulkDurable.Core.Worker)

    job = worker.new(%{bulk_action_id: bulk_action.id}, queue: queue)

    case Oban.insert(AshBulkDurable.Core.oban(), job) do
      {:ok, %Oban.Job{id: job_id}} ->
        bulk_action
        |> Ash.Changeset.for_update(:set_oban_job_id, %{oban_job_id: job_id}, authorize?: false)
        |> Ash.update(authorize?: false)

      {:error, term} ->
        {:error, {:enqueue_worker_failed, term}}
    end
  end
end
