defmodule AshBulkDurable.Core.LeaseTest do
  @moduledoc """
  The `bulk_actions` table as the queue: claims, leases, fencing, the attempt
  ceiling and the poller's drain.
  """
  use AshBulkDurable.DataCase, async: false

  require Ash.Query

  alias AshBulkDurable.Core.{Lease, Poller, Worker}
  alias AshBulkDurable.TakeoverResolver
  alias AshBulkDurable.Test.{Booking, BulkAction, Region, Row}

  @region_resource_name "AshBulkDurable.Test.Region"

  defp create_bulk_action!(user, n, opts \\ []) do
    suffix = System.unique_integer([:positive])

    rows =
      Enum.map(1..n, fn i ->
        %{input: %{name: "Region #{i}", native_name: "Region AR #{i}", code: "L#{i}-#{suffix}"}}
      end)

    bulk_action =
      Ash.create!(
        BulkAction,
        %{
          user_id: user.id,
          resource_name: @region_resource_name,
          action_name: :create,
          action_type: :create,
          total_rows: n,
          mode: Keyword.get(opts, :mode, :per_row),
          chunk_size: Keyword.get(opts, :chunk_size, 2),
          rows: rows
        },
        action: :create,
        authorize?: false
      )

    {bulk_action, suffix}
  end

  defp reload(%{id: id}),
    do: Ash.get!(BulkAction, id, authorize?: false, load: [:rows_done, :rows_pending])

  # Bookings have no unique key here, so a row applied twice shows as a
  # third record.
  defp create_bookings!(user, n, mode) do
    Ash.create!(
      BulkAction,
      %{
        user_id: user.id,
        resource_name: inspect(Booking),
        action_name: :import,
        action_type: :create,
        total_rows: n,
        mode: mode,
        chunk_size: n,
        rows: List.duplicate(%{input: %{}}, n)
      },
      action: :create,
      authorize?: false
    )
  end

  # Each row holds a reference the takeover resolver answers in phase 1.
  defp create_resolving_regions!(user, n, mode, suffix) do
    rows =
      Enum.map(1..n, fn i ->
        %{
          input: %{
            name: "Region #{i}",
            native_name: {:resolve, TakeoverResolver, "Region AR #{i}"},
            code: "T#{i}-#{suffix}"
          }
        }
      end)

    Ash.create!(
      BulkAction,
      %{
        user_id: user.id,
        resource_name: @region_resource_name,
        action_name: :create,
        action_type: :create,
        total_rows: n,
        mode: mode,
        chunk_size: n,
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  defp take_over_at_first_chunk(bulk_action) do
    handler = "take-over-#{bulk_action.id}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :chunk, :start],
      fn _event, _measurements, %{bulk_action_id: id}, _config ->
        if id == bulk_action.id do
          :telemetry.detach(handler)
          expire_lease!(bulk_action)
          {:ok, current} = Lease.claim_one(bulk_action.id)
          :ok = Worker.run(current)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Runs `fun` once, in the run's own process, when its first chunk starts:
  # after it read the chunk, before it writes it.
  defp at_first_chunk(bulk_action, fun) do
    handler = "at-first-chunk-#{bulk_action.id}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :chunk, :start],
      fn _event, _measurements, %{bulk_action_id: id}, _config ->
        if id == bulk_action.id do
          :telemetry.detach(handler)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp regions_from(suffix) do
    Region
    |> Ash.Query.filter(contains(code, ^"-#{suffix}"))
    |> Ash.read!(authorize?: false)
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  # What a node that died mid-run leaves: a lease in the past.
  defp expire_lease!(bulk_action) do
    Repo.query!(
      "UPDATE bulk_actions SET lease_until = now() - interval '1 second' WHERE id = $1",
      [
        Ecto.UUID.dump!(bulk_action.id)
      ]
    )
  end

  describe "claim" do
    # As a bulk action left `:running` by the Oban version is after the
    # upgrade: its lease was never set, so it counts as run out.
    test "takes a :running bulk action that has no lease", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)

      Repo.query!("UPDATE bulk_actions SET status = 'running' WHERE id = $1", [
        Ecto.UUID.dump!(bulk_action.id)
      ])

      assert {:ok, %{status: :running, attempts: 1}} = Lease.claim_one(bulk_action.id)
    end

    test "returns the token it wrote", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)
      {:ok, claimed} = Lease.claim_one(bulk_action.id)
      assert claimed.claim_token == reload(bulk_action).claim_token
    end

    test "takes a queued bulk action: running, a token, a lease and one attempt", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)

      assert {:ok, claimed} = Lease.claim_one(bulk_action.id)
      assert claimed.status == :running
      assert claimed.attempts == 1
      assert is_binary(claimed.claim_token)
      assert DateTime.compare(claimed.lease_until, DateTime.utc_now()) == :gt
      assert claimed.started_at
    end

    test "skips a bulk action whose lease is live", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)
      {:ok, _claimed} = Lease.claim_one(bulk_action.id)

      assert :none = Lease.claim_one(bulk_action.id)
      refute bulk_action.id in Enum.map(Lease.claim(10), & &1.id)
      assert :skipped = Worker.run_now(bulk_action.id)
    end

    test "takes the oldest first", ctx do
      {first, _} = create_bulk_action!(ctx.super_user, 1)
      {second, _} = create_bulk_action!(create_super_user(), 1)

      assert [%{id: id}] = Lease.claim(1)
      assert id == first.id
      assert [%{id: id}] = Lease.claim(1)
      assert id == second.id
    end
  end

  describe "an expired lease" do
    test "is claimed again and resumes, no succeeded row run twice", ctx do
      {bulk_action, suffix} = create_bulk_action!(ctx.super_user, 5)
      {:ok, first_claim} = Lease.claim_one(bulk_action.id)

      # The first claim committed three rows, then its node died.
      bulk_action
      |> rows()
      |> Enum.take(3)
      |> Enum.each(fn row ->
        Ash.update!(row, %{record_id: "stub"}, action: :mark_succeeded, authorize?: false)
      end)

      expire_lease!(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      finished = reload(bulk_action)
      assert finished.status == :completed
      assert finished.attempts == 2
      assert finished.claim_token != first_claim.claim_token
      assert finished.rows_done == 5
      assert length(regions_from(suffix)) == 2
    end
  end

  describe "fencing" do
    test "a run that lost its claim cannot finish the bulk action", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 2)
      {:ok, stale} = Lease.claim_one(bulk_action.id)
      expire_lease!(bulk_action)
      {:ok, current} = Lease.claim_one(bulk_action.id)

      # The stale run's first row write finds its claim gone: it writes
      # nothing, and stops.
      assert :lost = Worker.run(stale)
      assert Enum.all?(rows(bulk_action), &(&1.status == :resolved))

      held = reload(bulk_action)
      assert held.status == :running
      assert held.claim_token == current.claim_token
      assert held.finished_at == nil

      assert :ok = Worker.run(current)
      assert reload(bulk_action).status == :completed
    end

    test "a renewal by a lost claim says so and extends nothing", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)
      {:ok, claimed} = Lease.claim_one(bulk_action.id)

      assert :ok = Lease.renew(claimed.id, claimed.claim_token)
      assert :lost = Lease.renew(claimed.id, Ecto.UUID.generate())
    end

    test "a renewal after its own run finished says so, without extending", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)
      {:ok, claimed} = Lease.claim_one(bulk_action.id)
      :ok = Worker.run(claimed)

      assert :finished = Lease.renew(claimed.id, claimed.claim_token)
    end
  end

  describe "two runs at once" do
    # The stale run has read its chunk when the lease runs out and another
    # claim runs the bulk action to the end; then the stale run carries on.
    for mode <- [:per_row, :all_or_nothing] do
      test "#{mode}: a run whose claim was taken over writes no row twice", ctx do
        bulk_action = create_bookings!(ctx.super_user, 2, unquote(mode))
        {:ok, stale} = Lease.claim_one(bulk_action.id)
        before = Repo.aggregate(Booking, :count, :id)

        take_over_at_first_chunk(bulk_action)

        assert :lost = Worker.run(stale)

        assert Repo.aggregate(Booking, :count, :id) == before + 2
        assert %{status: :completed, rows_done: 2} = reload(bulk_action)
        assert Enum.all?(rows(bulk_action), &(&1.status == :succeeded))
      end
    end

    # The other order: the run that holds the claim has read its chunk when
    # the stale run, still going, tries to write those rows first. Its
    # writes confirm a claim it no longer holds, so it writes nothing.
    for mode <- [:per_row, :all_or_nothing] do
      test "#{mode}: a stale run going at the same time writes nothing", ctx do
        bulk_action = create_bookings!(ctx.super_user, 2, unquote(mode))
        {:ok, stale} = Lease.claim_one(bulk_action.id)
        expire_lease!(bulk_action)
        {:ok, current} = Lease.claim_one(bulk_action.id)
        before = Repo.aggregate(Booking, :count, :id)
        test_pid = self()

        at_first_chunk(bulk_action, fn ->
          send(test_pid, {:stale, Worker.run(stale)})
          send(test_pid, {:bookings, Repo.aggregate(Booking, :count, :id)})
        end)

        assert :ok = Worker.run(current)
        assert_received {:stale, :lost}
        assert_received {:bookings, ^before}

        assert Repo.aggregate(Booking, :count, :id) == before + 2
        assert %{status: :completed, rows_done: 2} = reload(bulk_action)
        assert Enum.all?(rows(bulk_action), &(&1.status == :succeeded))
      end
    end

    # Phase 1: the stale run has read its `:pending` rows and is resolving
    # them when another claim runs the bulk action to the end.
    for mode <- [:per_row, :all_or_nothing] do
      test "#{mode}: a run whose claim was taken over in phase 1 writes no row twice", ctx do
        suffix = System.unique_integer([:positive])
        bulk_action = create_resolving_regions!(ctx.super_user, 2, unquote(mode), suffix)
        {:ok, stale} = Lease.claim_one(bulk_action.id)
        on_exit(&TakeoverResolver.clear/0)

        TakeoverResolver.hook(fn ->
          expire_lease!(bulk_action)
          {:ok, current} = Lease.claim_one(bulk_action.id)
          :ok = Worker.run(current)
        end)

        assert :lost = Worker.run(stale)

        assert length(regions_from(suffix)) == 2
        assert %{status: :completed, rows_done: 2} = reload(bulk_action)
        assert Enum.all?(rows(bulk_action), &(&1.status == :succeeded))
      end
    end

    # The status check alone would let a stale run apply a row it read
    # before losing its claim, as long as the row's status still matches:
    # the claim check before each commit is what stops it.
    for mode <- [:per_row, :all_or_nothing] do
      test "#{mode}: a stale run writes nothing even where the rows' status still matches",
           ctx do
        bulk_action = create_bookings!(ctx.super_user, 2, unquote(mode))
        {:ok, stale} = Lease.claim_one(bulk_action.id)
        before = Repo.aggregate(Booking, :count, :id)

        # Taken over, but not run: the rows stay `:resolved`.
        at_first_chunk(bulk_action, fn ->
          expire_lease!(bulk_action)
          {:ok, _current} = Lease.claim_one(bulk_action.id)
        end)

        assert :lost = Worker.run(stale)
        assert Repo.aggregate(Booking, :count, :id) == before
        assert Enum.all?(rows(bulk_action), &(&1.status == :resolved))
      end
    end

    # A row read before a resolver's `lost/2` goes to storage, then applied
    # meanwhile, is not sent back to `:pending` to run again.
    test "a row applied since it was read is not forgotten back to :pending", ctx do
      bulk_action = create_bookings!(ctx.super_user, 1, :per_row)
      {:ok, current} = Lease.claim_one(bulk_action.id)
      before = Repo.aggregate(Booking, :count, :id)

      [row] = rows(bulk_action)
      assert :ok = Worker.run(current)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(row, %{names: ["file"]},
                 action: :forget_resolutions,
                 authorize?: false
               )

      assert Repo.aggregate(Booking, :count, :id) == before + 1
      assert %{status: :completed, rows_done: 1} = reload(bulk_action)
      assert [%{status: :succeeded}] = rows(bulk_action)
    end

    # Driven through runs: the run holding the claim has read its kept
    # resolutions and is asking `lost/2` about them when a stale run tries
    # to apply the row. The stale run writes nothing; the holder forgets
    # what was lost, resolves it again and applies the row once.
    test "a stale run stepping in while the holder asks lost/2 writes nothing", ctx do
      suffix = System.unique_integer([:positive])
      bulk_action = create_resolving_regions!(ctx.super_user, 1, :per_row, suffix)
      {:ok, first} = Lease.claim_one(bulk_action.id)
      on_exit(&TakeoverResolver.clear/0)
      handler = "forget-#{bulk_action.id}"
      test_pid = self()

      # Once the first run has resolved the row, two more claims take over.
      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :chunk, :start],
        fn _event, _measurements, %{bulk_action_id: id}, _config ->
          if id == bulk_action.id do
            :telemetry.detach(handler)
            expire_lease!(bulk_action)
            {:ok, stale} = Lease.claim_one(bulk_action.id)
            expire_lease!(bulk_action)
            {:ok, holder} = Lease.claim_one(bulk_action.id)

            TakeoverResolver.lost_hook(fn -> send(test_pid, {:stale, Worker.run(stale)}) end)
            send(test_pid, {:holder, Worker.run(holder)})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :lost = Worker.run(first)
      assert_received {:stale, :lost}
      assert_received {:holder, :ok}

      assert length(regions_from(suffix)) == 1
      assert %{status: :completed, rows_done: 1} = reload(bulk_action)
      assert [%{status: :succeeded}] = rows(bulk_action)
    end

    test "a stale run's failure leaves a row the other run wrote as it is", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)
      {:ok, _stale} = Lease.claim_one(bulk_action.id)
      expire_lease!(bulk_action)
      {:ok, current} = Lease.claim_one(bulk_action.id)
      :ok = Worker.run(current)

      [row] = rows(bulk_action)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(row, %{error: "late"}, action: :mark_failed, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(row, %{record_id: "late"}, action: :mark_succeeded, authorize?: false)

      assert [%{status: :succeeded}] = rows(bulk_action)
    end
  end

  describe "the progress counts" do
    test "count every row, whatever the reader may see of the rows", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 2)
      {:ok, claimed} = Lease.claim_one(bulk_action.id)
      :ok = Worker.run(claimed)

      # The owner, now allowed to read the bulk action but none of its rows.
      Repo.query!("UPDATE users SET platform_roles = '{row_blind}' WHERE id = $1", [
        Ecto.UUID.dump!(ctx.super_user.id)
      ])

      owner = Ash.get!(AshBulkDurable.Test.User, ctx.super_user.id, authorize?: false)
      assert [] = Ash.read!(Row, actor: owner)

      assert %{rows_done: 2, rows_pending: 0} =
               Ash.get!(BulkAction, bulk_action.id,
                 actor: owner,
                 load: [:rows_done, :rows_pending]
               )
    end
  end

  describe "progress broadcasts" do
    # The default `:progress_interval` (a second) is in force here, and the
    # run takes far less: only the broadcasts never throttled away arrive.
    test "an all-or-nothing run says when its references are resolved, however soon", ctx do
      suffix = System.unique_integer([:positive])
      bulk_action = create_resolving_regions!(ctx.super_user, 2, :all_or_nothing, suffix)
      topic = "bulk_action:#{bulk_action.id}"
      :ok = AshBulkDurable.Test.PubSub.subscribe(topic)

      {:ok, claimed} = Lease.claim_one(bulk_action.id)
      :ok = Worker.run(claimed)

      # In the order sent: what a page knew when the write began.
      committed_before_write =
        Stream.repeatedly(fn ->
          receive do
            {^topic, "progress", payload} -> payload
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&match?(%{committed: true}, &1))

      # The claim's, and the one after phase 1, which the throttle can't drop.
      assert length(committed_before_write) == 2
    end

    test "phase 1 says so as each row resolves", ctx do
      previous = Application.get_env(:ash_bulk_durable, :progress_interval)
      Application.put_env(:ash_bulk_durable, :progress_interval, 0)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_bulk_durable, :progress_interval, previous),
          else: Application.delete_env(:ash_bulk_durable, :progress_interval)
      end)

      suffix = System.unique_integer([:positive])
      bulk_action = create_resolving_regions!(ctx.super_user, 3, :all_or_nothing, suffix)
      topic = "bulk_action:#{bulk_action.id}"
      :ok = AshBulkDurable.Test.PubSub.subscribe(topic)
      {:ok, claimed} = Lease.claim_one(bulk_action.id)
      :ok = Worker.run(claimed)

      committed =
        Stream.repeatedly(fn ->
          receive do
            {^topic, "progress", payload} -> payload
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&match?(%{committed: true}, &1))

      # The claim's, one per resolved row, and the end of phase 1's (and the
      # chunk's, after its rows).
      assert length(committed) >= 1 + 3 + 1
    end
  end

  describe "the attempt ceiling" do
    test "a bulk action left with no lease on its last attempt is failed too", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)

      Repo.query!(
        "UPDATE bulk_actions SET status = 'running', attempts = $1 WHERE id = $2",
        [Lease.max_attempts(), Ecto.UUID.dump!(bulk_action.id)]
      )

      assert [%{id: id}] = Lease.fail_exhausted()
      assert id == bulk_action.id
    end

    test "only :max_attempts shutdowns are refunded", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)
      max = Lease.max_attempts()

      for _shutdown <- 1..max do
        {:ok, claimed} = Lease.claim_one(bulk_action.id)
        :ok = Lease.release(claimed.id, claimed.claim_token, refund: true)
        assert %{attempts: 0} = reload(bulk_action)
      end

      {:ok, claimed} = Lease.claim_one(bulk_action.id)
      :ok = Lease.release(claimed.id, claimed.claim_token, refund: true)
      assert %{attempts: 1, shutdowns: shutdowns} = reload(bulk_action)
      assert shutdowns == max + 1
    end

    test "a bulk action whose claims keep dying is failed :worker_lost", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)

      for attempt <- 1..Lease.max_attempts() do
        assert {:ok, %{attempts: ^attempt}} = Lease.claim_one(bulk_action.id)
        expire_lease!(bulk_action)
      end

      assert :none = Lease.claim_one(bulk_action.id)
      last = reload(bulk_action)
      assert [%{id: id}] = Lease.fail_exhausted()
      assert id == bulk_action.id

      failed = reload(bulk_action)
      assert failed.status == :failed
      assert failed.result["reason"] == "worker_lost"

      # A run of the last claim still alive somewhere is told to stop.
      assert :lost = Lease.renew(last.id, last.claim_token)

      # Its owner can retry it, which starts the count again.
      assert {:ok, %{status: :queued, attempts: 0}} =
               AshBulkDurable.retry(failed,
                 scope: AshBulkDurable.Test.Scope.new(actor: ctx.super_user)
               )
    end

    test "a live lease on its last attempt is left running", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)

      for _attempt <- 1..(Lease.max_attempts() - 1) do
        {:ok, _claimed} = Lease.claim_one(bulk_action.id)
        expire_lease!(bulk_action)
      end

      {:ok, _last} = Lease.claim_one(bulk_action.id)

      assert [] = Lease.fail_exhausted()
      assert reload(bulk_action).status == :running
    end
  end

  describe "a run that raises" do
    test "releases its lease, so a later poll claims it again" do
      # An owner gone by the time it runs: the worker's own read raises.
      owner = create_super_user()
      {bulk_action, _suffix} = create_bulk_action!(owner, 1)
      {:ok, claimed} = Lease.claim_one(bulk_action.id)
      Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(owner.id)])

      assert_raise Ash.Error.Invalid, fn -> Worker.run(claimed) end

      # Not straight away: a run that keeps raising backs off between claims.
      released = reload(bulk_action)
      assert released.status == :running
      assert DateTime.compare(released.lease_until, DateTime.utc_now()) == :gt
      assert :none = Lease.claim_one(bulk_action.id)

      expire_lease!(bulk_action)
      assert {:ok, %{attempts: 2}} = Lease.claim_one(bulk_action.id)
    end

    test "gives up the attempt, failing no row, when phase 1 can't check its claim", ctx do
      suffix = System.unique_integer([:positive])
      bulk_action = create_resolving_regions!(ctx.super_user, 1, :per_row, suffix)

      # Once the row is resolved, before its write confirms the claim: the
      # database fails every query on the bulk actions from then on.
      TakeoverResolver.hook(fn ->
        Repo.query!("ALTER TABLE bulk_actions RENAME TO bulk_actions_away")
      end)

      on_exit(&TakeoverResolver.clear/0)
      {:ok, claimed} = Lease.claim_one(bulk_action.id)

      assert_raise AshBulkDurable.Core.ClaimCheckError, fn -> Worker.run(claimed) end

      Repo.query!("ALTER TABLE bulk_actions_away RENAME TO bulk_actions")
      assert [%{status: :pending, error: nil}] = rows(bulk_action)
      assert %{status: :running} = reload(bulk_action)
    end

    test "drain/0 runs it to :failed when :retry_backoff is 0" do
      previous = Application.get_env(:ash_bulk_durable, :retry_backoff)
      Application.put_env(:ash_bulk_durable, :retry_backoff, 0)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_bulk_durable, :retry_backoff, previous),
          else: Application.delete_env(:ash_bulk_durable, :retry_backoff)
      end)

      owner = create_super_user()
      {bulk_action, _suffix} = create_bulk_action!(owner, 1)
      Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(owner.id)])

      max = Lease.max_attempts()
      assert %{success: 0, failure: ^max} = Worker.drain()
      assert %{status: :failed, result: %{"reason" => "raised"}} = reload(bulk_action)
    end

    test "fails with what it raised on its last attempt", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)

      for _attempt <- 1..(Lease.max_attempts() - 1) do
        {:ok, _claimed} = Lease.claim_one(bulk_action.id)
        expire_lease!(bulk_action)
      end

      {:ok, last} = Lease.claim_one(bulk_action.id)

      assert_raise FunctionClauseError, fn -> Worker.run(%{last | user_id: :not_a_user}) end

      failed = reload(bulk_action)
      assert failed.status == :failed
      assert failed.result["reason"] == "raised"
      assert failed.result["term"] =~ "FunctionClauseError"
    end
  end

  describe "the poller" do
    test "claims and runs a queued bulk action on a poll", ctx do
      {bulk_action, suffix} = create_bulk_action!(ctx.super_user, 3)

      poller =
        start_supervised!(
          {Poller, name: nil, poll_interval: :timer.hours(1), staging_sweep_interval: nil}
        )

      :ok = Poller.poll(poller)

      wait_until(fn -> reload(bulk_action).status == :completed end)
      assert length(regions_from(suffix)) == 3
      assert Poller.running(poller) == []
    end

    test "runs no more than :max_running at once", ctx do
      {first, _} = create_bulk_action!(ctx.super_user, 1)
      {second, _} = create_bulk_action!(create_super_user(), 1)

      poller =
        start_supervised!(
          {Poller,
           name: nil, max_running: 1, poll_interval: :timer.hours(1), staging_sweep_interval: nil}
        )

      :ok = Poller.poll(poller)
      assert Enum.count([reload(first), reload(second)], &(&1.status == :queued)) == 1
      wait_until(fn -> Poller.running(poller) == [] end)
    end

    test "claims the next bulk action as soon as a run ends", ctx do
      {first, _} = create_bulk_action!(ctx.super_user, 1)
      {second, _} = create_bulk_action!(create_super_user(), 1)

      poller =
        start_supervised!(
          {Poller,
           name: nil, max_running: 1, poll_interval: :timer.hours(1), staging_sweep_interval: nil}
        )

      :ok = Poller.poll(poller)
      # One poll, and no other: the second is claimed when the first ends.
      wait_until(fn ->
        Enum.all?([reload(first), reload(second)], &(&1.status not in [:queued, :running]))
      end)
    end

    test "claims a bulk action submitted on its node straight away", ctx do
      start_supervised!({Poller, poll_interval: :timer.hours(1), staging_sweep_interval: nil})
      suffix = System.unique_integer([:positive])

      {:ok, bulk_action} =
        AshBulkDurable.Core.create(
          Region,
          :create,
          [%{input: %{name: "Nudged", native_name: "Nudged AR", code: "N-#{suffix}"}}],
          scope: AshBulkDurable.Test.Scope.new(actor: ctx.super_user)
        )

      wait_until(fn -> reload(bulk_action).status == :completed end)
    end

    test "with no poller on the node, a submit warns once", ctx do
      previous = Application.get_env(:ash_bulk_durable, :warn_without_poller)
      Application.put_env(:ash_bulk_durable, :warn_without_poller, true)
      :persistent_term.erase({Poller, :warned})

      on_exit(fn ->
        Application.put_env(:ash_bulk_durable, :warn_without_poller, previous)
        :persistent_term.erase({Poller, :warned})
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          create_bulk_action!(ctx.super_user, 1)
          Poller.nudge()
          Poller.nudge()
        end)

      assert [_once] = Regex.scan(~r/no AshBulkDurable.Core.Poller runs on this node/, log)
    end

    test "on shutdown, releases a running bulk action and gives its attempt back", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)
      test_pid = self()
      handler = "poller-shutdown-#{bulk_action.id}"

      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :chunk, :start],
        fn _event, _measurements, %{bulk_action_id: id}, _config ->
          if id == bulk_action.id do
            send(test_pid, :running)
            Process.sleep(:infinity)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      start_supervised!(
        {Poller,
         name: :shutdown_poller, poll_interval: :timer.hours(1), staging_sweep_interval: nil}
      )

      :ok = Poller.poll(:shutdown_poller)
      assert_receive :running, 5000

      :ok = stop_supervised(Poller)

      released = reload(bulk_action)
      assert %{status: :running, attempts: 0} = released
      assert DateTime.compare(released.lease_until, DateTime.utc_now()) != :gt
      assert {:ok, %{attempts: 1}} = Lease.claim_one(bulk_action.id)
    end

    test "once drained, claims nothing", ctx do
      {bulk_action, _suffix} = create_bulk_action!(ctx.super_user, 1)

      poller =
        start_supervised!({Poller, name: nil, poll_interval: 10, staging_sweep_interval: nil})

      :ok = Poller.drain(poller)
      :ok = Poller.poll(poller)
      send(poller, :poll)

      assert Poller.running(poller) == []
      assert %{status: :queued, attempts: 0} = reload(bulk_action)
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("timed out")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end
end
