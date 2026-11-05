defmodule AshBulkDurable.Core.Worker do
  @moduledoc """
  Drives one claimed `BulkAction` through phase 1 (resolving its rows'
  references) and phase 2 (the chunk loop). `AshBulkDurable.Core.Poller`
  claims bulk actions and runs them here; `run_now/1` and `drain/0` run the
  same path in the caller, for tests and scripts.

  ## Crash-resume

  The row-state mutation IS the pagination. Phase 1 reads
  `:next_pending_chunk` (rows still `:pending`; a row holding no reference
  is stored `:resolved` and never read here) and flips them to `:resolved`;
  phase 2 reads `:next_resolved_chunk` (rows `:resolved` but not yet
  applied) and flips them to `:succeeded`. A later claim resumes at the next
  un-touched row in whichever phase the last one died in — no row committed
  twice.

  A node that dies holds its claim only until its lease runs out
  (`AshBulkDurable.Core.Lease`): the next poll on any node claims the bulk
  action again and resumes it. After `:max_attempts` claims it is failed
  `:worker_lost` instead, for its owner to retry, which resumes the same way.

  ## Fencing

  Every write to the bulk action filters on the claim token it was claimed
  with. Every row write is a compare-and-set on the row's status
  (`AshBulkDurable.Core.Changes.RequireStatus`), and confirms the claim
  token still holds just before its transaction commits
  (`AshBulkDurable.Core.Changes.RequireClaim` for one row,
  `AshBulkDurable.Core.Changes.RunRow` for a chunk). A run that lost its
  claim (its lease ran out while it still ran) writes nothing more: its row
  write fails, the target writes in that transaction roll back with it, and
  the run stops (`ClaimLostError`); its `mark_finished` matches no row.

  A row write refused while this run's token still holds can only be one
  already committing when the claim was taken; the step it happened in
  starts again from the rows' status, a few times at most.

  ## Failure surface

  - A bulk action storing what no longer decodes (`StoredTerm`) →
    `:mark_finished({:failed, %{reason: :unreadable}})`, nothing run. A row
    storing it fails alone.
  - Staged-file download error, with a row left for a resolver → each such
    row fails alone (`StagedFileError`) and the rest run. All or nothing →
    `:mark_finished({:failed, %{reason: :staged_file_download_error, ...}})`.
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
  one that returns an error, in either phase and either mode. Only a raise
  from the worker's own reads and writes ends the run: its lease is released
  so a later poll claims it again after `Lease.backoff/1`, and on the last
  attempt the bulk action is failed `:raised` with what was raised.

  ## Progress

  Nothing a chunk's transaction writes touches the bulk action's row; after
  each chunk commits, the worker broadcasts through
  `AshBulkDurable.Core.Progress` so a page recounts `rows_done`.

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
  """

  alias AshBulkDurable.Core.{
    Lease,
    Progress,
    Reference,
    Runner,
    StagedFileError,
    Storage,
    StoredTerm
  }

  require Ash.Expr
  require Ash.Query
  require Logger

  # A row's files run one after another, each an extraction and a PUT.
  @row_resolve_timeout :timer.minutes(5)

  # Where `run/1` keeps the claim it runs under, for its row writes.
  @claim_key {__MODULE__, :claim}

  # How often a run whose rows another run wrote first starts its step again
  # before giving the bulk action back.
  @max_resumes 3

  @doc """
  Claims the bulk action `id`, if it is claimable, and runs it in the
  caller. Returns `:ok` once it ran, or `:skipped` when it was not
  claimable: finished, or held by a live lease.
  """
  def run_now(id) do
    case Lease.claim_one(id) do
      {:ok, bulk_action} -> bulk_action |> run_apart() |> outcome!()
      :none -> :skipped
    end
  end

  @doc """
  Claims and runs, in the caller, every claimable bulk action, one at a
  time, until none is left. Returns `%{success: n, failure: m}`: the runs
  that returned and those that raised.

  A run that raised can't be claimed again until its backoff ends, so
  `drain/0` leaves it `:running`, not `:failed`. A host's tests that want
  it to reach `:failed` set `config :ash_bulk_durable, retry_backoff: 0`.
  """
  def drain, do: drain(%{success: 0, failure: 0})

  defp drain(acc) do
    case Lease.claim(1) do
      [] ->
        acc

      [bulk_action] ->
        case run_apart(bulk_action) do
          {:ok, _outcome} -> drain(%{acc | success: acc.success + 1})
          _raised -> drain(%{acc | failure: acc.failure + 1})
        end
    end
  end

  # `run/1` in a process of its own, watched rather than linked: a lease
  # renewer that finds the claim lost exits the run, and must not take the
  # test, script or shell that called `run_now/1` or `drain/0` with it.
  # `$callers` carries a test's sandboxed connection over.
  defp run_apart(bulk_action) do
    callers = [self() | Process.get(:"$callers", [])]

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        result =
          try do
            {:ok, run(bulk_action)}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        exit({:shutdown, {__MODULE__, result}})
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:shutdown, {__MODULE__, result}}} -> result
      {:DOWN, ^ref, :process, ^pid, {:lease_lost, _id}} -> {:ok, :lost}
      {:DOWN, ^ref, :process, ^pid, reason} -> {:raised, :exit, reason, []}
    end
  end

  defp outcome!({:ok, outcome}), do: outcome
  defp outcome!({:raised, kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  defmodule ClaimLostError do
    @moduledoc """
    Raised inside a run whose claim another run took over: a row it was about
    to flip had already moved on. The run stops; what it wrote in the
    transaction at hand rolls back.
    """
    defexception [:bulk_action_id]

    @impl true
    def message(%{bulk_action_id: id}), do: "bulk action #{id} was claimed by another run"
  end

  @doc """
  Runs a bulk action `AshBulkDurable.Core.Lease` claimed, holding its lease
  while it runs. Returns `:ok`, or `:lost` when another run took the claim
  over meanwhile and this one stopped. A raise, exit or throw from the
  worker's own reads and writes releases the lease for a later poll to claim
  it again after a backoff, or on the last attempt fails the bulk action
  `:raised`, and is raised again.

  The lease renewer is linked to the caller, and exits it when the claim is
  lost: call this from a process of its own, as the poller does.
  `run_now/1` and `drain/0` do that for you.
  """
  def run(bulk_action) do
    outer = Process.put(@claim_key, %{id: bulk_action.id, token: bulk_action.claim_token})

    try do
      Lease.hold(bulk_action, fn -> attempt(bulk_action) end)
    after
      Process.put(@claim_key, outer)
    end
  rescue
    exception in ClaimLostError ->
      Logger.warning(Exception.message(exception) <> "; stopping")
      :lost

    exception ->
      give_up_attempt(bulk_action, Exception.format_banner(:error, exception, __STACKTRACE__))
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      give_up_attempt(bulk_action, Exception.format_banner(kind, reason, __STACKTRACE__))
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # A row write refused means the row moved on under another run. If this
  # run's token still holds, that other run wrote it first (only possible for
  # a write already committing when this claim was taken, since every row
  # write confirms the claim before it commits), so `fun` starts again from
  # the rows' status. Otherwise, or after `@max_resumes`, this run stops.
  defp while_held(bulk_action, fun, resumes \\ 0) do
    fun.()
  rescue
    exception in ClaimLostError ->
      cond do
        not Lease.held?(bulk_action) ->
          reraise exception, __STACKTRACE__

        resumes >= @max_resumes ->
          Lease.release(bulk_action.id, bulk_action.claim_token)
          reraise exception, __STACKTRACE__

        true ->
          Logger.info("bulk action #{bulk_action.id}: another run wrote rows first; resuming")
          while_held(bulk_action, fun, resumes + 1)
      end
  end

  # A raise on the last attempt fails the bulk action with what was raised,
  # instead of leaving it to `Lease.fail_exhausted/0` as `:worker_lost`. An
  # earlier one releases the lease with a backoff before the next claim.
  defp give_up_attempt(bulk_action, banner) do
    if bulk_action.attempts >= Lease.max_attempts() do
      result = {:failed, %{reason: :raised, term: first_line(banner)}}
      # nil when another claim took it over: nothing left to release.
      mark_finished(bulk_action, result)
    else
      Lease.release(bulk_action.id, bulk_action.claim_token,
        retry_in: Lease.backoff(bulk_action.attempts)
      )
    end
  rescue
    _exception -> Lease.release(bulk_action.id, bulk_action.claim_token)
  end

  defp first_line(banner), do: banner |> String.split("\n", parts: 2) |> hd()

  defp attempt(bulk_action) do
    if StoredTerm.unreadable?(bulk_action) do
      mark_finished(bulk_action, {:failed, %{reason: :unreadable}})
      :ok
    else
      emit_worker_attempt_start(bulk_action)
      # The claim was a plain UPDATE, which no notifier saw.
      Progress.changed(bulk_action)
      scope = reconstruct_scope(bulk_action)
      drive_with_telemetry(bulk_action, scope)
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

  # A refused row write resumes the step it happened in (`while_held/2`),
  # not the attempt: the staged files are downloaded once, and deleted
  # however the run ends.
  defp drive(bulk_action, scope) do
    settings = Runner.settings(bulk_action, scope, %{})
    while_held(bulk_action, fn -> forget_lost_resolutions(bulk_action, settings) end)

    terminal_bulk_action =
      case download_staged_files_with_telemetry(bulk_action, settings) do
        {:ok, staged_paths} ->
          try do
            settings = %{settings | staged_files: staged_paths}
            while_held(bulk_action, fn -> run_rows(bulk_action, settings) end)
          after
            delete_local_staged_tmp(staged_paths)
          end

        {:error, reason} ->
          while_held(bulk_action, fn ->
            run_without_staged_files(bulk_action, settings, reason)
          end)
      end

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
      # Never throttled away: an all-or-nothing write commits nothing until
      # it ends, so a page that missed this would show phase 1 until then.
      Progress.changed(bulk_action, force: true)
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

  defp reconstruct_scope(bulk_action),
    do: AshBulkDurable.Core.Owner.scope_from_worker_key(bulk_action.user_id, bulk_action.tenant)

  # Fenced on the claim token: a run whose claim another took over matches no
  # row, writes nothing and returns nil, which stops it quietly. And only
  # while still `:running`: the run keeps its token once it finishes, and a
  # raise after that (`give_up_attempt/2`) must not overwrite the result.
  defp mark_finished(bulk_action, result) do
    bulk_action
    |> Ash.Changeset.for_update(:mark_finished, %{result: result}, authorize?: false)
    |> Lease.fenced(bulk_action)
    |> Ash.Changeset.filter(Ash.Expr.expr(status == :running))
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, finished} ->
        finished

      {:error, error} ->
        if Lease.stale?(error) do
          Logger.warning("bulk action #{bulk_action.id} was claimed by another run; stopping")
          nil
        else
          raise error
        end
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
    |> Enum.each(fn {row, names} -> forget_resolutions(row, names) end)
  end

  # Guarded like the other flips: the row was read before `lost/2` went to
  # storage, and a stale run may have applied it meanwhile.
  defp forget_resolutions(row, names) do
    case Ash.update(row, %{names: names},
           action: :forget_resolutions,
           authorize?: false,
           context: claim_context()
         ) do
      {:ok, forgotten} ->
        forgotten

      {:error, error} ->
        if claim_lost?(error),
          do: raise(ClaimLostError, bulk_action_id: row.bulk_action_id),
          else: raise(error)
    end
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
  # back through `drive/2` via `run_rows/3`), so the purge keys off the
  # status this run set; nil when another run took the claim over, which
  # purges for itself.
  defp maybe_delete_staging(nil), do: :ok

  defp maybe_delete_staging(bulk_action) do
    if delete_staging?(bulk_action.status) do
      Enum.each(bulk_action.staged_files, fn {_name, key} -> Storage.delete_object(key) end)
    end

    :ok
  end

  # A `:failed` bulk action can be retried, so its files stay for the
  # staging sweep to reclaim.
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
        result = resolve_chunk(chunk, settings, concurrency, atomic?)
        Progress.changed(bulk_action)

        case result do
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
    claim = Process.get(@claim_key)

    rows
    |> Task.async_stream(
      fn row -> {row, resolve_one_row(row, settings, resolvers, claim)} end,
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

  # Each resolved row has committed, so a page can count it (throttled).
  defp reduce_resolution({:ok, _resolved}, row, status, failed, _atomic?) do
    Progress.changed(%{id: row.bulk_action_id})
    {:cont, {status, failed}}
  end

  defp reduce_resolution({:error, err}, row, _status, failed, true) do
    raise_if_claim_unknown!(err)
    if claim_lost?(err), do: raise(ClaimLostError, bulk_action_id: row.bulk_action_id)
    mark_row_failed(row, err)
    {:halt, {:atomic_phase1_failed, {row.row_index, err}, failed + 1}}
  end

  defp reduce_resolution({:error, err}, row, status, failed, false) do
    raise_if_claim_unknown!(err)
    if claim_lost?(err), do: raise(ClaimLostError, bulk_action_id: row.bulk_action_id)
    mark_row_failed(row, err)
    {:cont, {status, failed + 1}}
  end

  # One row through the `:resolve` action. The resolution happens in the
  # action's `before_transaction` hook (`AshBulkDurable.Core.Changes.ResolveRow`);
  # the settings, in the row's tenant, and the prepared resolvers ride in on
  # the context.
  defp resolve_one_row(row, settings, resolvers, claim) do
    Ash.update(row, %{},
      action: :resolve,
      authorize?: false,
      context: %{ash_bulk_durable: %{settings: settings, resolvers: resolvers, claim: claim}}
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

  # Every row is `:succeeded` or `:failed` by now, so the succeeded ones
  # counted against the total tell which.
  defp finalize_bulk_action(bulk_action) do
    final_status =
      if succeeded_row_count(bulk_action.id) == bulk_action.total_rows do
        :completed
      else
        :completed_with_errors
      end

    mark_finished(bulk_action, final_status)
  end

  # All-or-nothing: the whole bulk action is one chunk, run in one transaction, so any
  # failure fails the bulk action. `bulk_run/5` drives the `:run` action over the chunk
  # — the action's after_batch creates the targets and flips row status, so the
  # worker never opens a transaction itself.
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
        Progress.changed(bulk_action)

        {:continue, chunk_measurements(length(chunk), succeeded, length(chunk) - succeeded),
         chunk_metadata(bulk_action, chunk_index, :rolled_back, :row_by_row)}
    end
  end

  # Re-run each row of a rolled-back chunk as its own batch of 1. A row that
  # still fails lands :failed with the clean error from the bulk result; the
  # `:run` action already marked the rest :succeeded. The page is told once,
  # after the chunk, not after each row.
  defp recover_row_by_row(chunk, settings, bulk_action) do
    Enum.reduce(chunk, 0, fn row, succeeded ->
      case bulk_run([row], settings, bulk_action, stop_on_error?: false, announce?: false) do
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
  # progress would stand still until the bulk action finished. An
  # all-or-nothing run also counts the rows its one transaction has processed,
  # for the hint `Progress.uncommitted/2` gives while it runs.
  #
  # A row that another run already wrote fails its compare-and-set flip
  # (`AshBulkDurable.Core.Changes.RequireStatus`): the batch rolls back and
  # this run stops, its claim lost.
  defp bulk_run(rows, settings, bulk_action, opts) do
    {announce?, opts} = Keyword.pop(opts, :announce?, true)

    context = %{
      settings: settings,
      bulk_action: bulk_action,
      processed: :counters.new(1, []),
      rows: length(rows),
      claim: Process.get(@claim_key)
    }

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
          context: %{ash_bulk_durable: context}
        ] ++ opts
      )

    case result.status do
      :success ->
        Ash.Notifier.notify(result.notifications)
        if announce?, do: Progress.changed(bulk_action)
        :ok

      _ ->
        if Enum.any?(List.wrap(result.errors), &claim_lost?/1),
          do: raise(ClaimLostError, bulk_action_id: bulk_action.id)

        {:error, first_error(result)}
    end
  end

  # The claim couldn't be checked, which says nothing about the row: the
  # attempt is given up, to resume after a backoff, rather than the row failed.
  defp raise_if_claim_unknown!(error) do
    case find_claim_check_error(error) do
      nil -> :ok
      claim_check_error -> raise claim_check_error
    end
  end

  defp find_claim_check_error(%AshBulkDurable.Core.ClaimCheckError{} = error), do: error

  defp find_claim_check_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_claim_check_error/1)

  defp find_claim_check_error(_error), do: nil

  # A row flip that matched no row: the row moved on under another run. A
  # target's own `StaleRecord` is a row failure like any other.
  defp claim_lost?(%Ash.Error.Changes.StaleRecord{resource: resource}),
    do: resource == row_resource()

  defp claim_lost?(%Ash.Changeset{errors: errors}), do: Enum.any?(errors, &claim_lost?/1)
  defp claim_lost?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &claim_lost?/1)
  defp claim_lost?(errors) when is_list(errors), do: Enum.any?(errors, &claim_lost?/1)
  defp claim_lost?(_error), do: false

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
  # path — target write + `:succeeded` flip — lives in the `:run` action's
  # after_batch (`AshBulkDurable.Core.Changes.RunRow`).
  #
  # Compare-and-set like the success flip: a row another run already wrote is
  # left as that run wrote it, and this run stops.
  defp mark_row_failed(row, err) do
    case Ash.update(row, %{error: err},
           action: :mark_failed,
           authorize?: false,
           context: claim_context()
         ) do
      {:ok, failed} ->
        failed

      {:error, error} ->
        if claim_lost?(error),
          do: raise(ClaimLostError, bulk_action_id: row.bulk_action_id),
          else: raise(error)
    end
  end

  # The claim this process runs under, for a row write to confirm before it
  # commits (`AshBulkDurable.Core.Changes.RequireClaim`).
  defp claim_context, do: %{ash_bulk_durable: %{claim: Process.get(@claim_key)}}

  # ── Telemetry ────────────────────────────────────────────────────

  # Emitted once a claim is taken, before anything runs. `attempt` counts the
  # bulk action's claims since it was submitted or last retried.
  # `pending_rows_at_start == total_rows` on attempt 1 is a cold start; a
  # smaller count on a later attempt is a crash resume.
  defp emit_worker_attempt_start(bulk_action) do
    :telemetry.execute(
      [:ash_bulk_durable, :worker_attempt, :start],
      %{system_time: System.system_time()},
      %{
        bulk_action_id: bulk_action.id,
        attempt: bulk_action.attempts,
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
    fresh =
      Ash.get!(bulk_action_resource(), bulk_action.id, authorize?: false, load: [:rows_done])

    measurements = %{
      rows_done: fresh.rows_done,
      rows_failed: failed_row_count(fresh.id)
    }

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
  defp reason_atom("raised"), do: :raised
  defp reason_atom("unreadable"), do: :unreadable
  defp reason_atom(_reason), do: nil

  defp pending_row_count(bulk_action) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :pending)
    |> Ash.count!(authorize?: false)
  end

  defp succeeded_row_count(bulk_action_id) do
    row_resource()
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id and status == :succeeded)
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
