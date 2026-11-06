defmodule AshBulkDurable.Core.Worker do
  @moduledoc """
  Drives a single `BulkAction` through phase 1 (resolving its rows'
  references) and phase 2 (the chunk loop).

  ## Running

  `run/2` is the run: a plain function, given the bulk action's id, that
  drives it from where its rows stand to its verdict. A host's
  `AshBulkDurable.Core.Poller` calls it in a task for each bulk action it
  starts.

  `run_now/1` and `drain/0` run bulk actions in the calling process, for a
  host's tests and scripts: `run_now/1` runs one, and `drain/0` every bulk
  action that is `:queued` or `:running`, oldest first. Phase 1's tasks
  inherit the caller's `$callers`, so a test's sandboxed connection reaches
  them.

  ## Crash-resume

  A run can die anywhere and start again, because the row-state mutation IS
  the pagination. Phase 1 reads `:next_pending_chunk` (rows still
  `:pending`; a row holding no reference is stored `:resolved` and never
  read here) and flips them to `:resolved`; phase 2 reads
  `:next_resolved_chunk` (rows `:resolved` but not yet applied) and flips
  them to `:succeeded`. The next run resumes at the next un-touched row in
  whichever phase the last died in — no row committed twice.

  A node that dies leaves its bulk action `:running`. Its liveness hint
  (`alive_at`, see `AshBulkDurable.Core.Liveness`) stops moving, and once it
  is older than the poller's `:stale_after` a poller starts the bulk action
  again, which resumes the same way. A run stamps the hint in its start
  transaction and in every chunk it commits, and a ticker linked to the run
  stamps it every `:alive_interval` between them.

  ## The bulk action lock

  Every phase-2 chunk runs in a transaction of its own that first locks the
  bulk action's row (`AshBulkDurable.Core.BulkActionLock`, `FOR NO KEY UPDATE
  SKIP LOCKED`) while it is `:queued` or `:running`, and only then reads its
  next rows, writes their targets, flips them and bumps `rows_done`. The one
  that finds no row left, or writes the last, writes the verdict. Before
  phase 1, a short locked transaction of its own starts the run: it takes
  the bulk action from `:queued` to `:running` and sets `started_at`, and a
  run that can't take the lock there stops before phase 1. Every
  verdict, phase 1's included, is written under the lock, from the record
  read under it. A chunk that fails rolls back with the lock; per row, its
  rows then run one at a time, each in a locked transaction of its own, and
  one that still fails is marked in a further one.

  Postgres releases the lock at commit, at rollback and when a connection
  dies, so a run that lost it has nothing left that can commit. A lock
  another transaction holds stops the run at once, writing nothing; `run/2`
  returns `:busy`.

  The lock covers only what is written on the bulk action's own connection,
  so every target must live in the bulk action's repo.

  Phase 1 runs outside the lock: it reaches for files and lookups, which can
  take minutes a row. Its single-row flips are compare-and-sets instead (see
  below).

  ## Failure surface

  - A bulk action storing what no longer decodes (`StoredTerm`) →
    `:mark_finished({:failed, %{reason: :unreadable}})`, nothing run. A row
    storing it fails alone.
  - Staged-file download error, with a row left for a resolver → each such
    row fails alone (`StagedFileError`) and the rest run. All or nothing →
    `:mark_finished({:failed, %{reason: :staged_file_download_error, ...}})`.
    Does NOT raise; we want a real terminal state, not a run that fails the
    same way every time it is started.
  - A resolver's `prepare/2` error for a chunk →
    `:mark_finished({:failed, %{reason: :resolver_prepare_error, ...}})`.
  - All-or-nothing phase 1 failure, or a row its caller already refused →
    `:mark_finished({:failed, %{reason: :atomic_phase1_failed, ...}})`.
  - All-or-nothing chunk rollback → `:mark_finished({:failed, %{reason:
    :atomic_chunk_rolled_back, ...}})`.
  - Per-row chunk rollback → row-by-row recovery (rows succeed or
    fail individually); the bulk action lands in `:completed_with_errors` if
    any row landed `:failed`.
  - A row status flip refused because another run of the bulk action already
    moved the row on (`RowMovedOnError`, see below) → the run stops, writing
    no verdict.

  A row that raises, or outruns `:row_resolve_timeout` in phase 1, fails like
  one that returns an error, in either phase and either mode. Only a raise from the worker's own reads and writes propagates
  out of the run; the bulk action stays `:running`, and is started again once
  its liveness hint goes stale.

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

  `run/2` short-circuits to `:ok` when the bulk action is already in a
  terminal state. A bulk action that turns terminal after that read is found
  so under the lock, and left as it is.

  ## Overlapping runs

  Two runs can overlap: two pollers can start the same bulk action, and a run
  can be started again while its first is still alive but has not stamped
  its hint in time. Between chunks a run holds nothing, so two runs take
  turns: each chunk reads the rows the last one left, and only one verdict is
  written, since a bulk action the other run finished no longer locks as
  running. Both may resolve the same rows in phase 1, which costs work, not
  data.

  Each row status flip is also a compare-and-set
  (`AshBulkDurable.Core.Changes.RequireStatus`), which is phase 1's only
  guard, and catches any phase-2 write that slips past the lock: the run that
  comes second to a row is refused, and the transaction holding the refused
  flip rolls back with whatever it wrote. The run then stops without writing
  anything more, and no verdict, returning `{:stopped, :row_moved_on}`; the
  other run carries the bulk action on.
  """

  alias AshBulkDurable.Core.{
    BulkActionLock,
    Liveness,
    Reference,
    Runner,
    StagedFileError,
    Storage,
    StoredTerm
  }

  alias AshBulkDurable.Core.Worker.RowMovedOnError

  require Ash.Query
  require Logger

  @runnable [:queued, :running]
  @ticker {__MODULE__, :ticker}

  # A row's files run one after another, each an extraction and a PUT.
  @row_resolve_timeout :timer.minutes(5)

  @doc """
  Runs the bulk action `bulk_action_id` once, in the calling process: phase 1,
  then phase 2, up to its verdict.

  Returns `:ok` when the run reached a verdict, or found nothing left to do
  (the bulk action is terminal); `:busy` when the run's start couldn't take
  the bulk action's lock, another transaction holding it, the bulk action no
  longer queued or running, or, with `:if_stale_after`, its liveness hint
  still fresh, and nothing was written; and
  `{:stopped, :row_moved_on}` when another run had moved one of its rows on,
  which stopped this one without a verdict. Raises what the run's own reads
  and writes raise.

  `opts`:

    * `:if_stale_after` - milliseconds. A `:running` bulk action whose
      liveness hint (`alive_at`) is newer than that, on the database's clock,
      is left alone, returning `:busy`: another run just started or stamped
      it. Checked under the lock, in the run's start transaction. Nil by
      default, which starts the bulk action whatever its hint; the poller
      passes its `:stale_after`.
    * `:attempt` - reported as `attempt` in the
      `[:ash_bulk_durable, :worker_attempt, :start]` event's metadata. Nil
      by default.
  """
  @spec run(Ash.UUID.t(), keyword()) :: :ok | :busy | {:stopped, :row_moved_on}
  def run(bulk_action_id, opts \\ []) do
    bulk_action = fetch_bulk_action!(bulk_action_id)

    if terminal?(bulk_action.status) do
      :ok
    else
      try do
        attempt(bulk_action, opts)
      rescue
        RowMovedOnError -> {:stopped, :row_moved_on}
      end
    end
  end

  @doc """
  Runs the bulk action `bulk_action_id` now, in the calling process, and
  returns what `run/2` returns. Phase 1's tasks inherit the caller's
  `$callers`, so a test's sandboxed connection reaches them.

  For hosts' tests and scripts: a test runs the bulk action it just submitted
  without a queue.
  """
  @spec run_now(Ash.UUID.t()) :: :ok | :busy | {:stopped, :row_moved_on}
  def run_now(bulk_action_id), do: run(bulk_action_id)

  @doc """
  Runs, oldest first and in the calling process, every bulk action that is
  `:queued` or `:running`, including any queued while it drains. Each runs at
  most once per call, so one left `:running` (busy, or stopped by a row
  another run moved on) can't loop forever. Returns how many it ran.

  For hosts' tests and scripts, as `run_now/1`.
  """
  @spec drain() :: non_neg_integer()
  def drain, do: drain(MapSet.new())

  defp drain(ran) do
    case next_runnable(ran) do
      nil ->
        MapSet.size(ran)

      bulk_action ->
        run_now(bulk_action.id)
        drain(MapSet.put(ran, bulk_action.id))
    end
  end

  defp next_runnable(ran) do
    ran = MapSet.to_list(ran)

    bulk_action_resource()
    |> Ash.Query.filter(status in [:queued, :running] and id not in ^ran)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp attempt(bulk_action, opts) do
    if StoredTerm.unreadable?(bulk_action) do
      finish_locked(bulk_action, {:failed, %{reason: :unreadable}})
      :ok
    else
      emit_worker_attempt_start(bulk_action, Keyword.get(opts, :attempt))

      bulk_action
      |> start_run(Keyword.get(opts, :if_stale_after))
      |> run_started(reconstruct_scope(bulk_action))
    end
  end

  # The ticker stamps the liveness hint for as long as the run goes, and stops
  # with it however it ends.
  defp run_started({:ok, running}, scope) do
    ticker = Liveness.start_ticker(running.id)
    Process.put(@ticker, ticker)

    try do
      drive_with_telemetry(running, scope)
    after
      Process.delete(@ticker)
      Liveness.stop_ticker(ticker)
    end
  end

  defp run_started(:busy, _scope), do: :busy

  # A run starts in a short locked transaction of its own, before phase 1:
  # it takes the bulk action from `:queued` to `:running`, sets `started_at`
  # and stamps the liveness hint, so the run shows as running, and is timed,
  # while its references resolve. A run that can't take the lock stops here,
  # before repeating another run's phase 1, as does one asked to leave a
  # bulk action another run stamped within `if_stale_after`.
  defp start_run(bulk_action, nil), do: locked(bulk_action.id, &stamped/1)

  defp start_run(bulk_action, if_stale_after),
    do: locked(bulk_action.id, &stamped/1, @runnable, Liveness.startable(if_stale_after))

  defp stamped(locked) do
    Liveness.stamp!(locked)
    locked
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

  defp drive(bulk_action, scope) do
    settings = Runner.settings(bulk_action, scope, %{})
    forget_lost_resolutions(bulk_action, settings)

    terminal_bulk_action =
      case download_staged_files_with_telemetry(bulk_action, settings) do
        {:ok, staged_paths} ->
          # A run stopped by a row that moved on raises past this.
          try do
            run_rows(bulk_action, %{settings | staged_files: staged_paths})
          after
            delete_local_staged_tmp(staged_paths)
          end

        {:error, reason} ->
          run_without_staged_files(bulk_action, settings, reason)
      end

    if terminal_bulk_action, do: maybe_delete_staging(terminal_bulk_action)
    :ok
  end

  # One transaction can't lose some rows, so all or nothing stops. Per row, a
  # row a resolver no longer has to reach for the files runs as it would.
  defp run_without_staged_files(%{mode: :all_or_nothing} = bulk_action, _settings, reason) do
    finish_locked(
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
  # the `:mark_finished` call that closed the attempt, or nil when another
  # transaction held the bulk action and this run stopped without one. That
  # fresh record is threaded back to `drive/2` so `maybe_delete_staging/1`
  # can act on it without a re-fetch window between the terminal write and
  # the purge decision.
  defp run_rows(bulk_action, settings) do
    with nil <- refused_row(bulk_action),
         :ok <- resolve_pending_rows(bulk_action, settings) do
      run_chunks(bulk_action, settings)
    else
      %{row_index: row_index, error: error} ->
        finish_locked(
          bulk_action,
          {:failed, atomic_failure_detail(:atomic_phase1_failed, error, row_index)}
        )

      {:atomic_phase1_failed, {row_index, err}} ->
        finish_locked(
          bulk_action,
          {:failed, atomic_failure_detail(:atomic_phase1_failed, err, row_index)}
        )

      {:prepare_failed, error} ->
        finish_locked(
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

  defp mark_finished(bulk_action, result) do
    Ash.update!(bulk_action, %{result: result}, action: :mark_finished, authorize?: false)
  end

  # ── The bulk action lock ───────────────────────────────────────────────

  @writing {__MODULE__, :writing}
  @chunk_span {__MODULE__, :chunk_span}

  # Runs `fun` in a transaction of its own that first locks the bulk action
  # (`BulkActionLock`, `SKIP LOCKED`) while its status is one of `statuses`
  # and it matches `filter`, and gives it the locked record, taken from
  # `:queued` to `:running` if it was queued. Returns `{:ok, result}`;
  # `:busy`, nothing written, when another transaction holds the lock or the
  # bulk action's status is another, or it doesn't match `filter`;
  # or `{:rolled_back, writing, error}` when rows `write_rows/5` was
  # writing failed, which rolls back the whole transaction, `writing` being
  # what it was given to remember. Ash announces what the transaction wrote
  # once it commits. The run's ticker is held meanwhile, so its stamp never
  # holds the lock this transaction takes (see `Liveness.hold/1`).
  defp locked(bulk_action_id, fun, statuses \\ @runnable, filter \\ true) do
    Process.delete(@writing)
    ticker = Process.get(@ticker)
    Liveness.hold(ticker)

    try do
      lock_and_run(bulk_action_id, fun, statuses, filter)
    after
      Liveness.release(ticker)
    end
  end

  defp lock_and_run(bulk_action_id, fun, statuses, filter) do
    Ash.transaction(
      [bulk_action_resource(), row_resource()],
      fn ->
        case BulkActionLock.lock(bulk_action_id, statuses, filter: filter) do
          {:ok, locked} -> {:ok, fun.(start_running(locked))}
          :none -> :busy
        end
      end
    )
    |> case do
      {:ok, result} ->
        Process.delete(@writing)
        result

      {:error, error} ->
        rolled_back(Process.delete(@writing), error, bulk_action_id)
    end
  end

  # A refused flip fails a batch like a row failure would, but it is not one:
  # another run wrote the row, so this one stops. Rolled back anywhere else,
  # the transaction raises as `Ash.update!/3` would.
  defp rolled_back(writing, error, bulk_action_id) do
    raise_if_moved_on!(error, bulk_action_id)
    if writing, do: {:rolled_back, writing, error}, else: raise(Ash.Error.to_error_class(error))
  end

  defp start_running(%{status: :queued} = locked),
    do: Ash.update!(locked, %{}, action: :mark_running, authorize?: false)

  defp start_running(locked), do: locked

  # A verdict written under the lock, read from the locked record: the
  # terminal bulk action, or nil when the lock was not taken.
  defp finish_locked(bulk_action, result, statuses \\ @runnable) do
    case locked(bulk_action.id, &mark_finished(&1, result), statuses) do
      {:ok, terminal} -> terminal
      :busy -> nil
    end
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
      row
      |> Ash.update(%{names: names}, action: :forget_resolutions, authorize?: false)
      |> row_flipped!(bulk_action.id)
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
  # here would reopen a window where another writer could land between the
  # terminal write and the purge decision, so the purge would key off a
  # status the worker never set.
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
    raise_if_moved_on!(err, row.bulk_action_id)
    mark_row_failed(row, err)
    {:halt, {:atomic_phase1_failed, {row.row_index, err}, failed + 1}}
  end

  defp reduce_resolution({:error, err}, row, status, failed, false) do
    raise_if_moved_on!(err, row.bulk_action_id)
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

  # Each chunk runs in a transaction of its own that holds the bulk action
  # lock (`locked/2`): its rows are read under the lock, written, and the
  # verdict written in the same transaction once no row is left. Between
  # chunks nothing is held, so another run may take a turn; each reads what
  # the last committed. Returns the terminal bulk action, or nil when another
  # transaction held the lock and this run stopped.
  defp run_chunks(bulk_action, settings), do: run_chunks(bulk_action, settings, 0)

  defp run_chunks(bulk_action, settings, chunk_index) do
    case run_chunk(bulk_action, settings, chunk_index) do
      :continue -> run_chunks(bulk_action, settings, chunk_index + 1)
      {:done, terminal} -> terminal
      :busy -> nil
    end
  end

  # A chunk that fails rolls back its transaction and releases the lock, so
  # what follows (recovery, a rollback verdict) runs in transactions of its
  # own. A raise anywhere after the chunk started, its commit and a row that
  # moved on included, closes its telemetry span with `:exception`.
  defp run_chunk(bulk_action, settings, chunk_index) do
    case locked(bulk_action.id, &write_next_chunk(&1, settings, chunk_index)) do
      {:ok, {:done, terminal}} ->
        {:done, terminal}

      {:ok, {:written, span, notifications, terminal}} ->
        Ash.Notifier.notify(notifications)
        chunk_stop(span, chunk_measurements(span.rows, span.rows, 0), :ok, :none)
        if terminal, do: {:done, terminal}, else: :continue

      {:rolled_back, {span, rows}, error} ->
        chunk_failed(bulk_action, settings, span, rows, error)

      :busy ->
        :busy
    end
  rescue
    exception -> chunk_exception(exception, __STACKTRACE__)
  end

  defp write_next_chunk(locked, settings, chunk_index) do
    case next_resolved_rows(locked, rows_per_chunk(locked)) do
      [] ->
        {:done, finalize_bulk_action(locked, 0)}

      rows ->
        span = chunk_start(locked, chunk_index, rows)

        notifications =
          write_rows(rows, settings, locked, {span, rows},
            stop_on_error?: locked.mode == :all_or_nothing
          )

        Liveness.stamp!(locked)
        {:written, span, notifications, finalize_if_last(locked, length(rows))}
    end
  end

  defp next_resolved_rows(locked, count) do
    row_resource()
    |> Ash.Query.for_read(:next_resolved_chunk, %{bulk_action_id: locked.id, chunk_size: count})
    |> Ash.read!(authorize?: false)
  end

  # The verdict, in the transaction that wrote the last rows.
  defp finalize_if_last(locked, written) do
    if next_resolved_rows(locked, 1) == [], do: finalize_bulk_action(locked, written)
  end

  # From the locked record and what this transaction wrote since it read it,
  # which the record it returns (and announces) counts too.
  defp finalize_bulk_action(locked, written) do
    locked = %{locked | rows_done: locked.rows_done + written}

    final_status =
      if locked.rows_done == locked.total_rows,
        do: :completed,
        else: :completed_with_errors

    mark_finished(locked, final_status)
  end

  # All or nothing: the whole bulk action is one chunk, so any failure fails
  # it, with the verdict written under the lock again: unless another run
  # holds it, or finished the bulk action meanwhile. The run started it, so
  # only a running one matches.
  defp chunk_failed(%{mode: :all_or_nothing} = bulk_action, _settings, span, _rows, error) do
    terminal =
      finish_locked(
        bulk_action,
        {:failed,
         atomic_failure_detail(:atomic_chunk_rolled_back, error, error_row_index(error))},
        [:running]
      )

    chunk_stop(span, chunk_measurements(span.rows, 0, span.rows), :rolled_back, :none)
    if terminal, do: {:done, terminal}, else: :busy
  end

  # Per row: the chunk rolled back (every row back to :resolved), so re-run
  # its rows one at a time: good rows commit individually and only the bad
  # ones land :failed.
  defp chunk_failed(bulk_action, settings, span, rows, _error) do
    {status, succeeded, failed} = recover_row_by_row(rows, settings, bulk_action)

    chunk_stop(
      span,
      chunk_measurements(span.rows, succeeded, failed),
      :rolled_back,
      :row_by_row
    )

    status
  end

  # Each row runs alone in a locked transaction of its own, and a row that
  # still fails is marked in a further one. A row no longer `:resolved` when
  # read under the lock was run by another run meanwhile, and is skipped; a
  # lock another transaction holds stops the recovery, since that run reads
  # these same rows and recovers them itself.
  defp recover_row_by_row(rows, settings, bulk_action) do
    Enum.reduce_while(rows, {:continue, 0, 0}, fn row, {:continue, succeeded, failed} ->
      case recover_row(row, settings, bulk_action) do
        :succeeded -> {:cont, {:continue, succeeded + 1, failed}}
        :failed -> {:cont, {:continue, succeeded, failed + 1}}
        :skipped -> {:cont, {:continue, succeeded, failed}}
        :busy -> {:halt, {:busy, succeeded, failed}}
      end
    end)
  end

  defp recover_row(row, settings, bulk_action) do
    case locked(bulk_action.id, &write_row_alone(&1, row, settings)) do
      {:ok, :skipped} ->
        :skipped

      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        :succeeded

      {:rolled_back, row, error} ->
        mark_failed_locked(row, error, bulk_action)

      :busy ->
        :busy
    end
  end

  defp write_row_alone(locked, row, settings) do
    case still_resolved(row) do
      nil -> :skipped
      fresh -> write_rows([fresh], settings, locked, fresh, stop_on_error?: false)
    end
  end

  defp still_resolved(row) do
    row_resource()
    |> Ash.Query.filter(id == ^row.id and status == :resolved)
    |> Ash.read_one!(authorize?: false)
  end

  # Only while the row, read again under the lock, is still `:resolved`: one
  # another run ran, or a retry reopened, since its own transaction rolled
  # back is skipped.
  defp mark_failed_locked(row, error, bulk_action) do
    case locked(bulk_action.id, fn _locked -> mark_if_resolved(row, error) end) do
      {:ok, :skipped} -> :skipped
      {:ok, _row} -> :failed
      :busy -> :busy
    end
  end

  defp mark_if_resolved(row, error) do
    case still_resolved(row) do
      nil -> :skipped
      fresh -> mark_row_failed(fresh, error)
    end
  end

  # Drives the `:run` action over a batch of Rows, inside the locked
  # transaction. The settings and the locked bulk action ride in on the
  # action context so the change doesn't rebuild them per chunk. Returns what
  # the batch would announce, to send once the transaction commits. A failed
  # batch rolls back the whole transaction, and with it anything the
  # transaction would return, so `writing` is kept aside for `locked/2` to
  # hand back.
  defp write_rows(rows, settings, locked, writing, opts) do
    Process.put(@writing, writing)

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
          context: %{ash_bulk_durable: %{settings: settings, bulk_action: locked}}
        ] ++ opts
      )

    case result.status do
      :success ->
        Process.delete(@writing)
        result.notifications || []

      _failed ->
        Ash.DataLayer.rollback(bulk_action_resource(), first_error(result))
    end
  end

  defp first_error(%{errors: [error | _]}), do: error
  defp first_error(_result), do: :unknown

  # `[:ash_bulk_durable, :chunk, :start | :stop | :exception]`, as
  # `:telemetry.span/3` would emit them, but split: a chunk starts once its
  # rows are read under the lock, and stops after its transaction commits,
  # or after its recovery.
  defp chunk_start(locked, chunk_index, rows) do
    start = System.monotonic_time()

    metadata = %{
      bulk_action_id: locked.id,
      chunk_index: chunk_index,
      rows_in_chunk: length(rows),
      telemetry_span_context: make_ref()
    }

    :telemetry.execute(
      [:ash_bulk_durable, :chunk, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      metadata
    )

    span = %{start: start, metadata: metadata, rows: length(rows)}
    Process.put(@chunk_span, span)
    span
  end

  defp chunk_stop(span, measurements, outcome, recovery) do
    Process.delete(@chunk_span)
    stop = System.monotonic_time()

    :telemetry.execute(
      [:ash_bulk_durable, :chunk, :stop],
      Map.merge(measurements, %{duration: stop - span.start, monotonic_time: stop}),
      %{
        bulk_action_id: span.metadata.bulk_action_id,
        chunk_index: span.metadata.chunk_index,
        outcome: outcome,
        recovery: recovery,
        telemetry_span_context: span.metadata.telemetry_span_context
      }
    )
  end

  defp chunk_exception(exception, stacktrace) do
    case Process.delete(@chunk_span) do
      nil ->
        :ok

      span ->
        stop = System.monotonic_time()

        :telemetry.execute(
          [:ash_bulk_durable, :chunk, :exception],
          %{duration: stop - span.start, monotonic_time: stop},
          Map.merge(span.metadata, %{kind: :error, reason: exception, stacktrace: stacktrace})
        )
    end

    reraise exception, stacktrace
  end

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

  # ── Row mutators ───────────────────────────────────────────────────────

  # Best-effort row-by-row recovery (and phase-1 resolution) mark failures
  # here, *outside* the row's own (rolled-back) `:run` transaction. The success
  # path — target write + `:succeeded` flip + `rows_done` bump — lives in the
  # `:run` action's after_batch (`AshBulkDurable.Core.Changes.RunRow`).
  defp mark_row_failed(row, err) do
    row
    |> Ash.update(%{error: err}, action: :mark_failed, authorize?: false)
    |> row_flipped!(row.bulk_action_id)
  end

  # A row status flip another run's write refused stops the run; any other
  # error raises as `Ash.update!/3` would.
  defp row_flipped!({:ok, row}, _bulk_action_id), do: row

  defp row_flipped!({:error, error}, bulk_action_id) do
    raise_if_moved_on!(error, bulk_action_id)
    raise Ash.Error.to_error_class(error)
  end

  defp raise_if_moved_on!(error, bulk_action_id) do
    if row_moved_on?(error), do: raise(RowMovedOnError, bulk_action_id: bulk_action_id)
    :ok
  end

  # True only for the row resource's own `StaleRecord`: a status flip's
  # compare-and-set refused (`RequireStatus`). A target's `StaleRecord` is an
  # ordinary row failure.
  defp row_moved_on?(%Ash.Error.Changes.StaleRecord{resource: resource}),
    do: resource == row_resource()

  defp row_moved_on?(%Ash.Changeset{errors: errors}), do: row_moved_on?(errors)
  defp row_moved_on?(%{errors: errors}) when is_list(errors), do: row_moved_on?(errors)
  defp row_moved_on?(errors) when is_list(errors), do: Enum.any?(errors, &row_moved_on?/1)
  defp row_moved_on?(_error), do: false

  # ── Telemetry ────────────────────────────────────────────────────

  # Emitted before any write, so the attempt is observable even if the
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
