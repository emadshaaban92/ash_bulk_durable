defmodule AshBulkDurable.Core.Worker do
  @moduledoc """
  Oban worker that drives a single `BulkAction` through phase 1
  (resolving its rows' references) and phase 2 (the chunk loop).

  ## Crash-resume

  `max_attempts: 3` is safe because the row-state mutation IS the
  pagination. Phase 1 reads `:next_pending_chunk` (rows still `:pending`;
  a row holding no reference is stored `:resolved` and never read here)
  and flips them to `:resolved`; phase 2 reads `:next_resolved_chunk`
  (rows `:resolved` but not yet applied) and flips them to `:succeeded`.
  A retry resumes at the next un-touched row in whichever phase it died
  in — no row committed twice.

  A node that dies takes no attempt with it: its job stays `:executing`, the
  run's `Heartbeat` stops, and `RescueStuckBulkActions` fails the bulk action
  for its owner to retry, which resumes the same way.

  ## Failure surface

  - A bulk action storing what no longer decodes (`StoredTerm`) →
    `:mark_finished({:failed, %{reason: :unreadable}})`, nothing run. A row
    storing it fails alone.
  - Staged-file download error, with a row left for a resolver → each such
    row fails alone (`StagedFileError`) and the rest run. All or nothing →
    `:mark_finished({:failed, %{reason: :staged_file_download_error, ...}})`.
    Does NOT raise; we want a real terminal state, not three Oban retries →
    rescue cron.
  - A resolver's `prepare/2` error for a chunk →
    `:mark_finished({:failed, %{reason: :resolver_prepare_error, ...}})`.
  - All-or-nothing phase 1 failure, or a row its caller already refused →
    `:mark_finished({:failed, %{reason: :atomic_phase1_failed, ...}})`.
  - All-or-nothing chunk rollback → `:mark_finished({:failed, %{reason:
    :atomic_chunk_rolled_back, ...}})`.
  - Per-row chunk rollback → row-by-row recovery (rows succeed or
    fail individually); the bulk action lands in `:completed_with_errors` if
    any row landed `:failed`.

  A row that raises, or outruns `:row_resolve_timeout` in phase 1, fails like
  one that returns an error, in either phase and either mode. Only a raise from the worker's own reads and writes propagates
  as a job failure, which is what triggers Oban's retry.

  ## Tenants

  A row acts in its target's tenant, or the bulk action's. Phase 1 resolves
  a chunk's tenant references first, then the rows' input references tenant
  by tenant, each tenant's resolvers prepared once. Phase 2 writes each row
  in its tenant; an all-or-nothing bulk action spanning tenants is still one
  transaction.

  ## Staged-file tmp cleanup

  Staged files land in a Briefly-managed tmp file. The eager
  `delete_local_staged_tmp/1` after `run_rows/3` returns
  removes them on the happy path; if the worker process crashes
  between download and that call, Briefly's `:DOWN` handler still
  cleans them up. Only a hard VM kill (`kill -9`, OOM-killer) can
  leak — at which point the OS tmp sweeper is the fallback.

  ## Idempotency on terminal bulk actions

  `perform/1` short-circuits to `:ok` when the bulk action is already in a
  terminal state. This closes the window where an attempt's BEAM
  process dies *after* `mark_finished` committed but *before* Oban
  acked the job: Oban will retry, but the next attempt sees a
  terminal bulk action and no-ops instead of re-running `mark_running`, which
  has no filter of its own and would take it back to `:running`.

  It does the same for a later attempt of a job the bulk action no longer
  names. A retry enqueues a new job while an attempt of the old one can still
  be waiting, and two would drive the same rows.
  """
  # The queue is host-configurable at enqueue time through the
  # `AshBulkDurable.Core.config/2` seam (see `AshBulkDurable.Core.Changes.EnqueueWorker`),
  # which is the single source of truth for `ash_bulk_durable` config. This
  # `:bulk_actions` literal is only the compile-time default Oban needs on
  # the worker; the insert-time `queue:` override is what actually runs.
  use Oban.Worker, queue: :bulk_actions, max_attempts: 3

  alias AshBulkDurable.Core.{
    Heartbeat,
    Reference,
    Runner,
    StagedFileError,
    Storage,
    StoredTerm
  }

  require Ash.Query
  require Logger

  # A row's files run one after another, each an extraction and a PUT.
  @row_resolve_timeout :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"bulk_action_id" => bulk_action_id}, attempt: attempt} = job) do
    bulk_action = fetch_bulk_action!(bulk_action_id)

    if terminal?(bulk_action.status) or superseded?(job, bulk_action) do
      :ok
    else
      attempt(bulk_action, job, attempt)
    end
  end

  defp attempt(bulk_action, job, attempt) do
    if StoredTerm.unreadable?(bulk_action) do
      mark_finished(bulk_action, {:failed, %{reason: :unreadable}})
      :ok
    else
      emit_worker_attempt_start(bulk_action, attempt)
      scope = reconstruct_scope(bulk_action)
      bulk_action = mark_running(bulk_action)

      Heartbeat.beating(job, fn -> drive_with_telemetry(bulk_action, scope) end)
    end
  end

  # `[:ash_bulk_durable, :bulk_action, :start | :stop | :exception]`. The bulk action
  # reaches one terminal `mark_finished` per attempt, so the stop event's
  # status/reason are read from the fresh row after `drive/2` returns.
  defp drive_with_telemetry(bulk_action, scope) do
    :telemetry.span(
      [:ash_bulk_durable, :bulk_action],
      bulk_action_start_metadata(bulk_action),
      fn ->
        drive(bulk_action, scope)
        {measurements, metadata} = bulk_action_stop(bulk_action)
        {:ok, measurements, metadata}
      end
    )
  end

  defp terminal?(status),
    do: status in [:completed, :completed_with_errors, :failed, :cancelled]

  # Only a later attempt can be late: a job is enqueued to be the one its bulk
  # action names, which keeps a job built for a test working too.
  defp superseded?(%Oban.Job{attempt: attempt, id: id}, %{oban_job_id: current}),
    do: attempt > 1 and id != current

  defp drive(bulk_action, scope) do
    settings = Runner.settings(bulk_action, scope, %{})
    forget_lost_resolutions(bulk_action, settings)

    {staged_paths_for_cleanup, terminal_bulk_action} =
      case download_staged_files_with_telemetry(bulk_action, settings) do
        {:ok, staged_paths} ->
          {staged_paths, run_rows(bulk_action, %{settings | staged_files: staged_paths})}

        {:error, reason} ->
          {%{}, run_without_staged_files(bulk_action, settings, reason)}
      end

    delete_local_staged_tmp(staged_paths_for_cleanup)
    maybe_delete_staging(terminal_bulk_action)
    :ok
  end

  # One transaction can't lose some rows, so all or nothing stops. Per row, a
  # row a resolver no longer has to reach for the files runs as it would.
  defp run_without_staged_files(%{mode: :all_or_nothing} = bulk_action, _settings, reason) do
    mark_finished(
      bulk_action,
      {:failed, %{reason: :staged_file_download_error, term: inspect(reason)}}
    )
  end

  defp run_without_staged_files(bulk_action, settings, reason) do
    Logger.error(
      "bulk action #{bulk_action.id} couldn't read its staged files: #{inspect(reason)}"
    )

    bulk_action
    |> pending_rows()
    |> Enum.filter(&Runner.resolver_pending?(settings, &1))
    |> Enum.each(&mark_row_failed(&1, %StagedFileError{}))

    run_rows(bulk_action, settings)
  end

  # Drives phase 1 + phase 2 and returns the terminal `BulkAction` from
  # the `:mark_finished` call that closed the attempt — every path
  # reaches one. That fresh record is threaded back to `drive/2` so
  # `maybe_delete_staging/1` can act on it without a re-fetch window
  # between the terminal write and the purge decision.
  defp run_rows(bulk_action, settings) do
    with nil <- refused_row(bulk_action),
         :ok <- resolve_pending_rows(bulk_action, settings) do
      run_chunks(bulk_action, settings)
    else
      %{row_index: row_index, error: error} ->
        mark_finished(
          bulk_action,
          {:failed, atomic_failure_detail(:atomic_phase1_failed, error, row_index)}
        )

      {:atomic_phase1_failed, {row_index, err}} ->
        mark_finished(
          bulk_action,
          {:failed, atomic_failure_detail(:atomic_phase1_failed, err, row_index)}
        )

      {:prepare_failed, error} ->
        mark_finished(
          bulk_action,
          {:failed, %{reason: :resolver_prepare_error, term: inspect(error)}}
        )
    end
  end

  # A row its caller refused before it was stored fails an all-or-nothing
  # bulk action before anything is resolved or written.
  defp refused_row(%{mode: :all_or_nothing} = bulk_action) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :failed)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp refused_row(_bulk_action), do: nil

  # ── Bulk action loading + scope rebuild ─────────────────────────────────────────

  defp fetch_bulk_action!(bulk_action_id) do
    Ash.get!(bulk_action_resource(), bulk_action_id, authorize?: false)
  end

  defp reconstruct_scope(bulk_action),
    do: AshBulkDurable.Core.Owner.scope_from_worker_key(bulk_action.user_id, bulk_action.tenant)

  defp mark_running(bulk_action) do
    Ash.update!(bulk_action, %{}, action: :mark_running, authorize?: false)
  end

  defp mark_finished(bulk_action, result) do
    Ash.update!(bulk_action, %{result: result}, action: :mark_finished, authorize?: false)
  end

  # ── Kept resolutions ───────────────────────────────────────────────────

  # A row left `:resolved` by a crash never reaches the resolve phase, and
  # a row that lost a file may be the only one needing the download: so what
  # rows lost while they waited is found here, before either.
  defp forget_lost_resolutions(bulk_action, settings) do
    row_resource()
    |> Ash.Query.filter(
      bulk_action_id == ^bulk_action.id and status in [:pending, :resolved] and
        resolved_data != ^%{}
    )
    |> Ash.read!(authorize?: false)
    |> then(&Runner.lost_resolutions(settings, &1))
    |> Enum.each(fn {row, names} ->
      Ash.update!(row, %{names: names}, action: :forget_resolutions, authorize?: false)
    end)
  end

  # ── Staged-file download ───────────────────────────────────────────────

  # `[:ash_bulk_durable, :staged_files_download, :stop]`. Wraps the storage→tmp
  # fetch so a download error also surfaces an `:exception` event.
  defp download_staged_files_with_telemetry(bulk_action, settings) do
    :telemetry.span(
      [:ash_bulk_durable, :staged_files_download],
      %{bulk_action_id: bulk_action.id},
      fn ->
        result = download_staged_files(bulk_action, settings)
        {measurements, metadata} = staged_files_download_stop(bulk_action.id, result)
        {result, measurements, metadata}
      end
    )
  end

  defp staged_files_download_stop(bulk_action_id, {:ok, paths}) do
    {%{file_count: map_size(paths), bytes_downloaded: total_staged_bytes(paths)},
     %{bulk_action_id: bulk_action_id}}
  end

  defp staged_files_download_stop(bulk_action_id, {:error, _reason}) do
    {%{file_count: 0, bytes_downloaded: 0}, %{bulk_action_id: bulk_action_id}}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp total_staged_bytes(paths) do
    Enum.reduce(paths, 0, fn {_field, path}, acc ->
      case File.stat(path) do
        {:ok, %{size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  # Keyed as they were staged, for the resolvers that read them.
  defp download_staged_files(%{staged_files: keys}, _settings) when map_size(keys) == 0,
    do: {:ok, %{}}

  # Only a resolver reads a staged file, and the engine can't tell which one
  # it reads: one row left to resolve downloads them all, and none downloads
  # none, so a retry that needs no file outlives the staging sweep.
  defp download_staged_files(bulk_action, settings) do
    if resolver_pending?(bulk_action, settings),
      do: fetch_staged_files(bulk_action.staged_files),
      else: {:ok, %{}}
  end

  defp resolver_pending?(bulk_action, settings) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :pending)
    |> Ash.stream!(authorize?: false, batch_size: 500, allow_stream_with: :offset)
    |> Enum.any?(&Runner.resolver_pending?(settings, &1))
  end

  defp pending_rows(bulk_action) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :pending)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_staged_files(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn {name, key}, {:ok, acc} ->
      case fetch_one_blob(key) do
        {:ok, tmp_path} ->
          {:cont, {:ok, Map.put(acc, name, tmp_path)}}

        {:error, term} ->
          {:halt, {:error, term}}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp fetch_one_blob(key) do
    case Storage.get_object(key) do
      {:ok, body} ->
        tmp = Briefly.create!(prefix: "ash_bulk_durable_")
        File.write!(tmp, body)
        {:ok, tmp}

      {:error, term} ->
        {:error, term}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp delete_local_staged_tmp(staged_paths) do
    Enum.each(staged_paths, fn {_name, path} -> File.rm(path) end)
  end

  # Acts on the terminal record returned by `mark_finished/2` (threaded
  # back through `drive/2` via `run_rows/3`). Re-reading the bulk action
  # here would reopen a window where the rescue cron — or any other
  # writer — could land between the terminal write and the purge
  # decision, so the purge would key off a status the worker never set.
  defp maybe_delete_staging(bulk_action) do
    if delete_staging?(bulk_action.status) do
      Enum.each(bulk_action.staged_files, fn {_name, key} -> Storage.delete_object(key) end)
    end

    :ok
  end

  # A `:failed` bulk action can be retried, so its files stay for the daily
  # sweep to reclaim.
  defp delete_staging?(:completed), do: true
  defp delete_staging?(:cancelled), do: true
  defp delete_staging?(_other), do: false

  # ── Phase 1: resolving references ──────────────────────────────────────

  # `[:ash_bulk_durable, :phase1, :start | :stop | :exception]`. Span
  # result is the status (`:ok` or `{:atomic_phase1_failed, err}`); resolved
  # vs failed counts ride the stop event's measurements.
  #
  # Only rows holding a reference are `:pending`; the per-row `:resolve`
  # action runs over each `:pending` chunk via `Task.async_stream`. The
  # resolution happens in `:resolve`'s `before_transaction` (outside any
  # transaction), bounded by `:phase1_concurrency`. NOTE: keep
  # `:phase1_concurrency` below the DB pool size — each in-flight resolve
  # takes a connection for its (short) write.
  defp resolve_pending_rows(bulk_action, settings) do
    concurrency = AshBulkDurable.Core.config(:phase1_concurrency, 4)
    to_resolve = pending_row_count(bulk_action)

    start_metadata = %{
      bulk_action_id: bulk_action.id,
      rows_to_resolve: to_resolve,
      concurrency: concurrency
    }

    :telemetry.span([:ash_bulk_durable, :phase1], start_metadata, fn ->
      {status, failed} = resolve_chunks(bulk_action, settings, concurrency)
      measurements = %{rows_resolved: to_resolve - failed, rows_failed: failed}
      {status, measurements, %{bulk_action_id: bulk_action.id}}
    end)
  end

  # Chunk the `:pending` rows the same way phase 2 chunks `:resolved` rows.
  # Each chunk's rows resolve concurrently; a resolved row flips to
  # `:resolved`, leaving `:pending`, so the next read returns the next
  # slice — state mutation is the pagination. Returns `{status, failed}`.
  defp resolve_chunks(bulk_action, settings, concurrency) do
    atomic? = bulk_action.mode == :all_or_nothing
    do_resolve_chunks(bulk_action, settings, concurrency, atomic?, 0)
  end

  # An all-or-nothing bulk action is one chunk in one transaction, whatever
  # its `chunk_size`; that only sizes a per-row bulk action's batches.
  defp rows_per_chunk(%{mode: :all_or_nothing, total_rows: total_rows}), do: total_rows
  defp rows_per_chunk(%{mode: :per_row, chunk_size: chunk_size}), do: chunk_size

  defp do_resolve_chunks(bulk_action, settings, concurrency, atomic?, failed_acc) do
    chunk =
      row_resource()
      |> Ash.Query.for_read(:next_pending_chunk, %{
        bulk_action_id: bulk_action.id,
        chunk_size: rows_per_chunk(bulk_action)
      })
      |> Ash.read!(authorize?: false)

    case chunk do
      [] ->
        {:ok, failed_acc}

      chunk ->
        case resolve_chunk(chunk, settings, concurrency, atomic?) do
          {:ok, failed} ->
            do_resolve_chunks(bulk_action, settings, concurrency, atomic?, failed_acc + failed)

          {:atomic_phase1_failed, err, failed} ->
            {{:atomic_phase1_failed, err}, failed_acc + failed}

          {:prepare_failed, error} ->
            {{:prepare_failed, error}, failed_acc}
        end
    end
  end

  # The chunk's tenants first: a row whose tenant can't be resolved fails
  # there. The rest resolve tenant by tenant, so a resolver is readied in the
  # tenant it resolves for.
  defp resolve_chunk(chunk, settings, concurrency, atomic?) do
    case Runner.resolve_tenants(settings, chunk) do
      {:ok, tenants} ->
        {tenanted, refused} =
          Enum.split_with(tenants, fn {_row, result} -> match?({:ok, _}, result) end)

        refused
        |> Enum.reduce_while({:ok, 0}, fn {row, result}, {status, failed} ->
          reduce_resolution(result, row, status, failed, atomic?)
        end)
        |> resolve_tenant_groups(tenanted, settings, concurrency, atomic?)

      {:error, error} ->
        {:prepare_failed, error}
    end
  end

  defp resolve_tenant_groups({:ok, failed}, tenanted, settings, concurrency, atomic?) do
    tenanted
    |> Enum.group_by(fn {_row, {:ok, tenant}} -> tenant end, fn {row, _tenant} -> row end)
    |> Enum.reduce_while({:ok, failed}, fn {tenant, rows}, {:ok, failed} ->
      case resolve_group(rows, %{settings | tenant: tenant}, concurrency, atomic?) do
        {:ok, group_failed} ->
          {:cont, {:ok, failed + group_failed}}

        {:atomic_phase1_failed, err, group_failed} ->
          {:halt, {:atomic_phase1_failed, err, failed + group_failed}}

        {:prepare_failed, error} ->
          {:halt, {:prepare_failed, error}}
      end
    end)
  end

  defp resolve_tenant_groups(halted, _tenanted, _settings, _concurrency, _atomic?), do: halted

  # A group's resolvers are readied once for all its rows, and released
  # whatever the rows' outcome.
  defp resolve_group(rows, settings, concurrency, atomic?) do
    references = Runner.references(settings, rows)

    case Reference.prepare(references, Runner.resolver_context(settings)) do
      {:ok, resolvers} ->
        try do
          resolve_rows(rows, settings, resolvers, concurrency, atomic?)
        after
          Reference.finish(resolvers)
        end

      {:error, error, resolvers} ->
        Reference.finish(resolvers)
        {:prepare_failed, error}
    end
  end

  # The timeout runs per task, and an overrun kills only that task, so one
  # slow row fails alone. Left to the default it would exit this process,
  # where no rescue reaches, and every attempt would meet the same row.
  defp resolve_rows(rows, settings, resolvers, concurrency, atomic?) do
    timeout = AshBulkDurable.Core.config(:row_resolve_timeout, @row_resolve_timeout)

    rows
    |> Task.async_stream(
      fn row -> {row, resolve_one_row(row, settings, resolvers)} end,
      max_concurrency: concurrency,
      ordered: false,
      timeout: timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.reduce_while({:ok, 0}, fn
      {:ok, {row, result}}, {status, failed} ->
        reduce_resolution(result, row, status, failed, atomic?)

      {:exit, {row, :timeout}}, {status, failed} ->
        error = Runner.row_timed_out(timeout, row)
        reduce_resolution({:error, error}, row, status, failed, atomic?)
    end)
  end

  defp reduce_resolution({:ok, _resolved}, _row, status, failed, _atomic?),
    do: {:cont, {status, failed}}

  defp reduce_resolution({:error, err}, row, _status, failed, true) do
    mark_row_failed(row, err)
    {:halt, {:atomic_phase1_failed, {row.row_index, err}, failed + 1}}
  end

  defp reduce_resolution({:error, err}, row, status, failed, false) do
    mark_row_failed(row, err)
    {:cont, {status, failed + 1}}
  end

  # One row through the `:resolve` action. The resolution happens in the
  # action's `before_transaction` hook (`AshBulkDurable.Core.Changes.ResolveRow`);
  # the settings, in the row's tenant, and the prepared resolvers ride in on
  # the context.
  defp resolve_one_row(row, settings, resolvers) do
    Ash.update(row, %{},
      action: :resolve,
      authorize?: false,
      context: %{ash_bulk_durable: %{settings: settings, resolvers: resolvers}}
    )
  rescue
    exception -> Runner.row_raised(exception, __STACKTRACE__, row)
  end

  # ── Phase 2: chunk loop ────────────────────────────────────────────────

  defp run_chunks(bulk_action, settings),
    do: do_run_chunks(bulk_action, settings, 0)

  # Each chunk's transaction gets its own `[:ash_bulk_durable, :chunk, …]` span.
  # The recursion lives *outside* the span so chunks are siblings,
  # not nested — and `run_chunk/5` returns `:continue` / `:halt` so an
  # all-or-nothing rollback stops the loop while per-row keeps going.
  defp do_run_chunks(bulk_action, settings, chunk_index) do
    chunk =
      row_resource()
      |> Ash.Query.for_read(:next_resolved_chunk, %{
        bulk_action_id: bulk_action.id,
        chunk_size: rows_per_chunk(bulk_action)
      })
      |> Ash.read!(authorize?: false)

    case chunk do
      [] ->
        finalize_bulk_action(bulk_action)

      chunk ->
        case run_chunk(bulk_action, settings, chunk, chunk_index) do
          :continue -> do_run_chunks(bulk_action, settings, chunk_index + 1)
          {:halt, terminal_bulk_action} -> terminal_bulk_action
        end
    end
  end

  defp run_chunk(bulk_action, settings, chunk, chunk_index) do
    start_metadata = %{
      bulk_action_id: bulk_action.id,
      chunk_index: chunk_index,
      rows_in_chunk: length(chunk)
    }

    :telemetry.span([:ash_bulk_durable, :chunk], start_metadata, fn ->
      process_chunk(bulk_action, settings, chunk, chunk_index)
    end)
  end

  defp finalize_bulk_action(bulk_action) do
    fresh = Ash.get!(bulk_action_resource(), bulk_action.id, authorize?: false)

    final_status =
      if fresh.rows_done == fresh.total_rows do
        :completed
      else
        :completed_with_errors
      end

    mark_finished(fresh, final_status)
  end

  # All-or-nothing: the whole bulk action is one chunk, run in one transaction, so any
  # failure fails the bulk action. `bulk_run/5` drives the `:run` action over the chunk
  # — the action's after_batch creates the targets, flips row status, and bumps
  # rows_done, so the worker never opens a transaction itself.
  defp process_chunk(bulk_action, settings, chunk, chunk_index)
       when bulk_action.mode == :all_or_nothing do
    case bulk_run(chunk, settings, bulk_action, stop_on_error?: true) do
      :ok ->
        {:continue, chunk_measurements(length(chunk), length(chunk), 0),
         chunk_metadata(bulk_action, chunk_index, :ok, :none)}

      {:error, error} ->
        terminal =
          mark_finished(
            bulk_action,
            {:failed,
             atomic_failure_detail(:atomic_chunk_rolled_back, error, error_row_index(error))}
          )

        {{:halt, terminal}, chunk_measurements(length(chunk), 0, length(chunk)),
         chunk_metadata(bulk_action, chunk_index, :rolled_back, :none)}
    end
  end

  # Per row: try the chunk as one atomic batch; on any failure the batch
  # rolled back (every row back to :resolved), so re-run the rows one at a
  # time — good rows commit individually and only the bad ones land :failed.
  defp process_chunk(bulk_action, settings, chunk, chunk_index) do
    case bulk_run(chunk, settings, bulk_action, stop_on_error?: false) do
      :ok ->
        {:continue, chunk_measurements(length(chunk), length(chunk), 0),
         chunk_metadata(bulk_action, chunk_index, :ok, :none)}

      {:error, _error} ->
        succeeded = recover_row_by_row(chunk, settings, bulk_action)

        {:continue, chunk_measurements(length(chunk), succeeded, length(chunk) - succeeded),
         chunk_metadata(bulk_action, chunk_index, :rolled_back, :row_by_row)}
    end
  end

  # Re-run each row of a rolled-back chunk as its own batch of 1. A row that
  # still fails lands :failed with the clean error from the bulk result; the
  # `:run` action already marked the rest :succeeded and bumped rows_done.
  defp recover_row_by_row(chunk, settings, bulk_action) do
    Enum.reduce(chunk, 0, fn row, succeeded ->
      case bulk_run([row], settings, bulk_action, stop_on_error?: false) do
        :ok ->
          succeeded + 1

        {:error, error} ->
          mark_row_failed(row, error)
          succeeded
      end
    end)
  end

  # Drives the `:run` action over a batch of Rows. The settings ride in on
  # the action context so the change doesn't rebuild them per chunk. `transaction: :all` makes the batch atomic.
  # What the batch wrote is announced once it commits: left queued, a page's
  # progress would stand still until the bulk action finished.
  defp bulk_run(rows, settings, bulk_action, opts) do
    result =
      Ash.bulk_update(
        rows,
        :run,
        %{},
        [
          strategy: :stream,
          transaction: :all,
          return_records?: true,
          return_errors?: true,
          return_notifications?: true,
          authorize?: false,
          context: %{ash_bulk_durable: %{settings: settings, bulk_action: bulk_action}}
        ] ++ opts
      )

    case result.status do
      :success ->
        Ash.Notifier.notify(result.notifications)
        :ok

      _ ->
        {:error, first_error(result)}
    end
  end

  defp first_error(%{errors: [error | _]}), do: error
  defp first_error(_result), do: :unknown

  # An all-or-nothing failure names the first offending row (0-based, when
  # identifiable) and keeps its error, so the progress panel can tell the
  # user what to fix, not just that the bulk action rolled back.
  defp atomic_failure_detail(reason, error, row_index) do
    detail = %{reason: reason, error: error}
    if row_index, do: Map.put(detail, :row_index, row_index), else: detail
  end

  # `Ash.bulk_update` surfaces a failed row as the errored *target*
  # changeset (the target's create or update built by
  # `Runner.run_row/2`), which carries its row index on
  # the context. A Row changeset (a target that couldn't be read, or a
  # failed status flip) carries it on `data` instead. Splode error classes (`Ash.Error.Invalid`,
  # `Ash.Error.Unknown`, …) often arrive with a nil top-level changeset
  # but their nested `:errors` carry the originating changeset — walk the
  # list rather than falling through to nil.
  defp error_row_index(%Ash.Changeset{context: %{ash_bulk_durable: %{row_index: row_index}}}),
    do: row_index

  defp error_row_index(%Ash.Changeset{data: %{row_index: row_index}}), do: row_index
  defp error_row_index(%{changeset: %Ash.Changeset{} = changeset}), do: error_row_index(changeset)

  defp error_row_index(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &error_row_index/1)

  defp error_row_index(_error), do: nil

  defp chunk_measurements(rows_in_chunk, succeeded, failed) do
    %{rows_in_chunk: rows_in_chunk, rows_succeeded: succeeded, rows_failed: failed}
  end

  defp chunk_metadata(bulk_action, chunk_index, outcome, recovery) do
    %{
      bulk_action_id: bulk_action.id,
      chunk_index: chunk_index,
      outcome: outcome,
      recovery: recovery
    }
  end

  # ── Row mutators ───────────────────────────────────────────────────────

  # Best-effort row-by-row recovery (and phase-1 resolution) mark failures
  # here, *outside* the row's own (rolled-back) `:run` transaction. The success
  # path — target write + `:succeeded` flip + `rows_done` bump — lives in the
  # `:run` action's after_batch (`AshBulkDurable.Core.Changes.RunRow`).
  defp mark_row_failed(row, err) do
    Ash.update!(row, %{error: err},
      action: :mark_failed,
      authorize?: false
    )
  end

  # ── Telemetry ────────────────────────────────────────────────────

  # Emitted before `mark_running` so the attempt is observable even if the
  # bulk action never starts. `pending_rows_at_start == total_rows` on attempt 1 is
  # a cold start; a smaller count on a later attempt is a crash resume.
  defp emit_worker_attempt_start(bulk_action, attempt) do
    :telemetry.execute(
      [:ash_bulk_durable, :worker_attempt, :start],
      %{system_time: System.system_time()},
      %{
        bulk_action_id: bulk_action.id,
        attempt: attempt,
        pending_rows_at_start: pending_row_count(bulk_action)
      }
    )
  end

  defp bulk_action_start_metadata(bulk_action) do
    %{
      bulk_action_id: bulk_action.id,
      user_id: bulk_action.user_id,
      resource_name: bulk_action.resource_name,
      action_name: bulk_action.action_name,
      total_rows: bulk_action.total_rows,
      chunk_size: bulk_action.chunk_size,
      mode: bulk_action.mode
    }
  end

  defp bulk_action_stop(bulk_action) do
    fresh = Ash.get!(bulk_action_resource(), bulk_action.id, authorize?: false)

    measurements = %{rows_done: fresh.rows_done, rows_failed: failed_row_count(fresh.id)}

    metadata = %{
      bulk_action_id: fresh.id,
      status: fresh.status,
      failure_reason: failure_reason(fresh)
    }

    {measurements, metadata}
  end

  defp failure_reason(%{status: status}) when status != :failed, do: nil
  defp failure_reason(%{result: %{"reason" => reason}}), do: reason_atom(reason)
  defp failure_reason(_run), do: nil

  # Map the serialized `result["reason"]` string back to its atom. Explicit
  # clauses (no `String.to_atom/1`) keep this to the known failure set — an
  # unrecognized reason yields nil rather than minting a new atom.
  defp reason_atom("resolver_prepare_error"), do: :resolver_prepare_error
  defp reason_atom("atomic_phase1_failed"), do: :atomic_phase1_failed
  defp reason_atom("atomic_chunk_rolled_back"), do: :atomic_chunk_rolled_back
  defp reason_atom("staged_file_download_error"), do: :staged_file_download_error
  defp reason_atom("worker_lost"), do: :worker_lost
  defp reason_atom(_reason), do: nil

  defp pending_row_count(bulk_action) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :pending)
    |> Ash.count!(authorize?: false)
  end

  defp failed_row_count(bulk_action_id) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id and status == :failed)
    |> Ash.count!(authorize?: false)
  end

  # ── Resource lookups ───────────────────────────────────────────────────

  defp bulk_action_resource, do: AshBulkDurable.Core.config(:bulk_action_resource)
  defp row_resource, do: AshBulkDurable.Core.config(:row_resource)
end
