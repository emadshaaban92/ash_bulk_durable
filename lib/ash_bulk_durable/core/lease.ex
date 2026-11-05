defmodule AshBulkDurable.Core.Lease do
  @moduledoc """
  The `bulk_actions` table is the queue: a bulk action is claimed, held and
  given up through the three columns this module writes, `lease_until`,
  `claim_token` and `attempts`.

  ## Claiming

  `claim/1` takes the oldest bulk actions that are `:queued`, or `:running`
  with a lease that has run out, and are under the attempt ceiling. It locks
  them `FOR UPDATE SKIP LOCKED`, so two nodes polling at once claim disjoint
  bulk actions, and in the same statement sets them `:running`, gives each a
  new `claim_token`, a lease of `:lease_duration`, one more attempt and a
  `started_at` of now. The claim and the reload of what it claimed share one
  transaction: a reload that fails rolls the claim back, so nothing is ever
  leased without being run.

  ## Holding

  While a run is live, `hold/2` renews its lease every third of
  `:lease_duration`, fenced on the claim token. Nothing a run writes inside a
  chunk's transaction touches the bulk action's row, so a renewal never waits
  behind one, however long an all-or-nothing transaction runs. A renewal that
  finds the token changed means another claimer owns the bulk action: the
  run is stopped.

  ## Losing

  A node that dies renews nothing. Its lease runs out, the next poll on any
  node claims the bulk action again, and the rows resume from their status.
  A bulk action whose claims keep dying reaches `:max_attempts` and is failed
  with the reason `:worker_lost` by `fail_exhausted/0`, which frees its owner
  to retry it.

  Every write the worker makes to its bulk action filters on the claim token
  (`fenced/2`), so a run that lost its claim cannot overwrite the verdict of
  the run that took it over.
  """

  require Ash.Query
  require Logger

  import Ash.Expr

  alias AshBulkDurable.Core
  alias AshBulkDurable.Core.ClaimCheckError

  # The timestamp columns hold UTC without a zone, as Ash writes them.
  @now "(now() AT TIME ZONE 'utc')"

  @lease_duration :timer.minutes(1)
  @max_attempts 3
  @retry_backoff :timer.seconds(15)

  @doc "How long a claim or a renewal holds a bulk action, in milliseconds."
  def lease_duration, do: Core.config(:lease_duration, @lease_duration)

  @doc "How many claims a bulk action gets before it is failed `:worker_lost`."
  def max_attempts, do: Core.config(:max_attempts, @max_attempts)

  @doc """
  Claims up to `limit` bulk actions, oldest first, and returns them loaded.
  Never raises: a database error is logged and claims nothing, so a poller
  just tries again on its next poll.
  """
  def claim(limit) when is_integer(limit) and limit > 0, do: claim_where("", [limit])

  @doc """
  Claims the bulk action `id` alone, if it is claimable. Returns `{:ok,
  bulk_action}` or `:none`.
  """
  def claim_one(id) do
    case claim_where("AND id = $3", [1, Ecto.UUID.dump!(id)]) do
      [bulk_action] -> {:ok, bulk_action}
      [] -> :none
    end
  end

  defp claim_where(extra, [limit | params]) do
    # A materialized CTE runs its locking SELECT once. As a subquery in
    # `FROM` it may be run again for each row the UPDATE visits, and a rerun
    # skips the row just claimed and claims the next: past `limit`.
    sql = """
    WITH claimable AS MATERIALIZED (
      SELECT id FROM #{table()}
      WHERE (status = 'queued'
             OR (status = 'running' AND (lease_until IS NULL OR lease_until <= #{@now})))
        AND attempts < #{max_attempts()}
        #{extra}
      ORDER BY inserted_at ASC, id ASC
      LIMIT #{limit}
      FOR UPDATE SKIP LOCKED
    )
    UPDATE #{table()} AS b
    SET status = 'running',
        claim_token = $1,
        lease_until = #{@now} + make_interval(secs => $2),
        attempts = b.attempts + 1,
        started_at = #{@now},
        updated_at = #{@now}
    FROM claimable
    WHERE b.id = claimable.id
    RETURNING b.id
    """

    # One token per claim statement; the bulk actions it claimed share it, and
    # each is held, renewed and fenced by its own id and that token.
    token = Ecto.UUID.generate()

    repo().transaction(fn ->
      with {:ok, %{rows: rows}} <-
             repo().query(sql, [Ecto.UUID.dump!(token), lease_seconds() | params]),
           {:ok, claimed} <- rows |> Enum.map(&claimed_id/1) |> load() do
        # The token this statement wrote, not the reload's: a host reading
        # from a replica could reload the row as it was before the claim.
        Enum.map(claimed, &%{&1 | claim_token: token})
      else
        {:error, error} -> repo().rollback(error)
      end
    end)
    |> case do
      {:ok, claimed} ->
        claimed

      {:error, error} ->
        Logger.error("ash_bulk_durable: claiming bulk actions failed: #{inspect(error)}")
        []
    end
  rescue
    exception ->
      Logger.error(
        "ash_bulk_durable: claiming bulk actions failed: #{Exception.message(exception)}"
      )

      []
  end

  defp claimed_id([id]), do: Ecto.UUID.load!(id)

  defp load([]), do: {:ok, []}

  defp load(ids) do
    bulk_action_resource()
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read(authorize?: false)
  end

  @doc """
  Runs `fun` while renewing `bulk_action`'s lease, and returns what it
  returns. The renewer is linked: when it finds the claim taken over, or
  can't renew before the last lease it was granted runs out, it exits
  `{:lease_lost, id}`, which stops the run with it.
  """
  def hold(bulk_action, fun) do
    renewer = spawn_renewer(bulk_action)

    try do
      fun.()
    after
      stop_renewer(renewer)
    end
  end

  defp spawn_renewer(%{id: id, claim_token: token}) do
    interval = max(div(lease_duration(), 3), 1)
    # Counted from now, a little before the claim's own lease runs out.
    deadline = lease_deadline(System.monotonic_time(:millisecond), interval)
    # `Task` so a test's sandboxed connection is shared through `$callers`.
    {:ok, pid} = Task.start_link(fn -> renew_loop(id, token, interval, deadline) end)
    pid
  end

  # When the lease last granted runs out, by this node's monotonic clock,
  # less half a renewal interval of margin for the clocks to disagree.
  defp lease_deadline(granted_at, interval),
    do: granted_at + lease_duration() - div(interval, 2)

  # Unlinked first: a renewal racing the run's last write must not take the
  # finished run down with it.
  defp stop_renewer(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      :timer.seconds(5) ->
        Process.exit(pid, :kill)
        :ok
    end
  end

  # A renewal that fails on a database error is tried again, but only while
  # the last lease granted lasts: past it another node may hold the claim,
  # so the run stops as if it had been told so. Neither the wait nor the
  # renewal's own query outlasts the deadline, so a renewal stuck behind a
  # lock can't keep the run going past it.
  defp renew_loop(id, token, interval, deadline) do
    receive do
      :stop -> :ok
    after
      min(interval, time_left(deadline)) ->
        asked_at = System.monotonic_time(:millisecond)

        case time_left(deadline) > 0 && renew(id, token, timeout: time_left(deadline)) do
          false ->
            exit({:lease_lost, id})

          :ok ->
            renew_loop(id, token, interval, lease_deadline(asked_at, interval))

          :finished ->
            :ok

          :lost ->
            exit({:lease_lost, id})

          {:error, _error} ->
            renew_loop(id, token, interval, deadline)
        end
    end
  end

  defp time_left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @doc """
  Pushes the lease of bulk action `id` out by `:lease_duration`, if `token`
  still holds it and it is still `:running`. Returns `:ok`; `:finished` when
  the run holding `token` has finished it; `:lost` when another claim, a
  retry or `fail_exhausted/0` took it from `token`; or `{:error, error}` on
  a database error, which is logged: a few missed renewals cost nothing
  while the lease lasts, and the renewer stops the run once it doesn't.
  `timeout:` bounds each of its queries, in milliseconds.
  """
  def renew(id, token, opts \\ []) do
    opts = Keyword.take(opts, [:timeout])

    sql = """
    UPDATE #{table()}
    SET lease_until = #{@now} + make_interval(secs => $3)
    WHERE id = $1 AND claim_token = $2 AND status = 'running'
    """

    case repo().query(sql, [Ecto.UUID.dump!(id), Ecto.UUID.dump!(token), lease_seconds()], opts) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> not_renewed(id, token, opts)
      {:error, error} -> missed(id, error)
    end
  rescue
    exception -> missed(id, exception)
  end

  # The run's own `mark_finished` keeps its token; every other way off
  # `:running` clears or replaces it.
  defp not_renewed(id, token, opts) do
    sql = "SELECT claim_token FROM #{table()} WHERE id = $1"

    case repo().query(sql, [Ecto.UUID.dump!(id)], opts) do
      {:ok, %{rows: [[held]]}} ->
        if held == Ecto.UUID.dump!(token), do: :finished, else: :lost

      {:ok, %{rows: []}} ->
        :lost

      {:error, error} ->
        missed(id, error)
    end
  end

  defp missed(id, error) do
    Logger.warning(
      "ash_bulk_durable: bulk action #{id} missed a lease renewal: #{inspect(error)}"
    )

    {:error, error}
  end

  @doc """
  Ends the lease of a run that crashed, if `token` still holds it, so a
  later poll claims the bulk action again instead of waiting the lease out.

  Options:

    * `retry_in: ms` — claimable again only after `ms` (see `backoff/1`), so
      a run that keeps raising doesn't use up its attempts back to back.
    * `refund: true` — the claim's attempt is given back too: a run its own
      node stopped on shutdown (`AshBulkDurable.Core.Poller`) did nothing
      wrong, and a rolling deploy must not use up a healthy run's attempts.
      Only `:max_attempts` shutdowns are refunded, so a bulk action whose
      nodes keep being stopped still reaches the ceiling.
  """
  def release(id, token, opts \\ []) do
    refund =
      if Keyword.get(opts, :refund, false) do
        ", attempts = CASE WHEN shutdowns < #{max_attempts()} " <>
          "THEN greatest(attempts - 1, 0) ELSE attempts END, shutdowns = shutdowns + 1"
      end

    retry_in = Keyword.get(opts, :retry_in, 0) / 1000

    sql = """
    UPDATE #{table()}
    SET lease_until = #{@now} + make_interval(secs => $3)#{refund}
    WHERE id = $1 AND claim_token = $2 AND status = 'running'
    """

    _ = repo().query(sql, [Ecto.UUID.dump!(id), Ecto.UUID.dump!(token), retry_in])
    :ok
  rescue
    _exception -> :ok
  end

  @doc """
  How long a bulk action whose run raised on attempt `n` waits before it is
  claimed again: `:retry_backoff` (15 seconds) times `n` squared.
  """
  def backoff(n), do: Core.config(:retry_backoff, @retry_backoff) * n * n

  @doc """
  True while `bulk_action`'s claim token still holds it and it runs. Raises
  on a database error, which tells nothing about the claim.
  """
  def held?(%{id: id, claim_token: token}) do
    sql = "SELECT 1 FROM #{table()} WHERE id = $1 AND claim_token = $2 AND status = 'running'"

    case repo().query(sql, [Ecto.UUID.dump!(id), Ecto.UUID.dump!(token)]) do
      {:ok, %{num_rows: 1}} -> true
      {:ok, %{num_rows: 0}} -> false
      {:error, error} -> raise error
    end
  end

  @doc """
  Fails every bulk action whose lease ran out on its last attempt, with the
  reason `:worker_lost`. A bulk action claimed again in the meantime is
  left alone. Returns the bulk actions it failed.
  """
  def fail_exhausted do
    max = max_attempts()

    # On the database's clock, the one that wrote `lease_until`: a node whose
    # clock runs ahead must not fail a run that is still renewing.
    bulk_action_resource()
    |> Ash.Query.filter(
      status == :running and attempts >= ^max and
        (is_nil(lease_until) or lease_until <= fragment("(now() AT TIME ZONE 'utc')"))
    )
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(fn bulk_action ->
      bulk_action
      |> Ash.Changeset.for_update(:mark_finished, %{result: {:failed, %{reason: :worker_lost}}},
        authorize?: false
      )
      |> fenced(bulk_action)
      |> Ash.Changeset.filter(
        expr(is_nil(lease_until) or lease_until <= fragment("(now() AT TIME ZONE 'utc')"))
      )
      # A run still alive somewhere finds its renewal refused, and stops.
      |> Ash.Changeset.force_change_attribute(:claim_token, nil)
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, failed} -> [failed]
        {:error, _stale} -> []
      end
    end)
  end

  @doc """
  Inside a transaction, confirms `token` still holds the bulk action `id`,
  and keeps it held until the transaction ends: `SELECT … FOR SHARE`, which
  a renewal's `UPDATE` waits behind and a claim (`SKIP LOCKED`) skips.
  Returns `:ok`, `:lost`, or `{:error, %AshBulkDurable.Core.ClaimCheckError{}}`
  on a database error, which tells nothing about the claim. A row write
  calls it last, just before its transaction commits.
  """
  def confirm_claim(id, token) do
    sql = """
    SELECT 1 FROM #{table()}
    WHERE id = $1 AND claim_token = $2 AND status = 'running'
    FOR SHARE
    """

    case repo().query(sql, [Ecto.UUID.dump!(id), Ecto.UUID.dump!(token)]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> :lost
      {:error, error} -> {:error, ClaimCheckError.exception(bulk_action_id: id, error: error)}
    end
  end

  @doc """
  Filters a bulk action update on the claim token `bulk_action` was claimed
  with, so it matches no row once another claim has taken over.
  """
  # A bulk action never claimed by this queue (left `:running` by an
  # upgrade) has no token to match on.
  def fenced(changeset, %{claim_token: nil}) do
    Ash.Changeset.filter(changeset, expr(is_nil(claim_token)))
  end

  def fenced(changeset, %{claim_token: token}) do
    Ash.Changeset.filter(changeset, expr(claim_token == ^token))
  end

  @doc "True when `error` is an update that matched no row: the claim was lost."
  def stale?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

  def stale?(_error), do: false

  defp lease_seconds, do: lease_duration() / 1000

  defp table do
    resource = bulk_action_resource()
    table = AshPostgres.DataLayer.Info.table(resource)

    case AshPostgres.DataLayer.Info.schema(resource) do
      nil -> ~s("#{table}")
      schema -> ~s("#{schema}"."#{table}")
    end
  end

  defp repo, do: AshPostgres.DataLayer.Info.repo(bulk_action_resource(), :mutate)
  defp bulk_action_resource, do: Core.config(:bulk_action_resource)
end
