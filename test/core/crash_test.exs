defmodule AshBulkDurable.Core.CrashTest do
  @moduledoc """
  Runs that die without returning: counting the starts that made no
  progress, running rows alone once a bulk action stalls, and failing the
  row that keeps killing its run. A killed run's transaction rolls back on
  its own connection while what it committed before stays, so this test
  runs outside the sandbox, each run in a process of its own, and deletes
  what it wrote.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  defmodule EchoResolver do
    @moduledoc "Resolves a value to itself."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context), do: {:ok, value}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule KillingResolver do
    @moduledoc "Kills the run resolving it: its task, and the run linked to it."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_value, nil, _context), do: Process.exit(self(), :kill)

    @impl true
    def finish(nil), do: :ok
  end

  defmodule ResettingResolver do
    @moduledoc """
    Resolves while another writer takes every bump back from the pending rows
    of the bulk actions of the user it is given.
    """
    @behaviour AshBulkDurable.Core.Resolver

    alias AshBulkDurable.Test.Repo

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(user_id, nil, _context) do
      Repo.query!(
        "UPDATE bulk_action_rows SET attempts = 0 WHERE status = 'pending' AND bulk_action_id IN " <>
          "(SELECT id FROM bulk_actions WHERE user_id = $1)",
        [Ecto.UUID.dump!(user_id)]
      )

      {:ok, "resolved #{user_id}"}
    end

    @impl true
    def finish(nil), do: :ok
  end

  alias AshBulkDurable.Core.{CrashedRowError, Retry, Worker}
  alias AshBulkDurable.Test.{BulkAction, Region, Repo, Row, Scope, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    tag = "crash#{System.unique_integer([:positive])}"

    user = create_user!(tag)
    on_exit(fn -> cleanup(tag) end)
    %{user: user, scope: Scope.new(actor: user), tag: tag}
  end

  describe "counting stalled starts" do
    test "the first start stores the score, counts none, and clears isolating_row_id", ctx do
      bulk_action = submit!(ctx, 2)
      [r1, _r2] = rows(bulk_action)
      # Left by a run that died for real while running row 1 alone.
      set!(bulk_action, "isolating_row_id = $2", [Ecto.UUID.dump!(r1.id)])

      assert %{progress_at_start: nil, stalled_starts: 0} = reload(bulk_action)
      assert :ok = Worker.run_now(bulk_action.id)

      # Both rows `:resolved` when it started: moved on, not finished.
      assert %{status: :completed, progress_at_start: 2, stalled_starts: 0, isolating_row_id: nil} =
               reload(bulk_action)
    end

    test "a start without progress adds one", ctx do
      bulk_action = submit!(ctx, 2, chunk_size: 2)
      kill_on_row(ctx, 2)

      assert :killed = attempt(bulk_action)
      assert %{progress_at_start: 2, stalled_starts: 0} = reload(bulk_action)

      assert :killed = attempt(bulk_action)
      assert %{progress_at_start: 2, stalled_starts: 1} = reload(bulk_action)
    end

    test "a start after progress, phase 1's included, sets it back to 0", ctx do
      bulk_action = submit_resolving!(ctx, [{EchoResolver, "a"}, {EchoResolver, "b"}])
      [r1, _r2] = rows(bulk_action)

      # Two stalled starts so far, the last scoring both rows `:pending`.
      set!(bulk_action, "progress_at_start = 0, stalled_starts = 2")
      # Since then, a run resolved one row.
      set_row!(r1, ~s(status = 'resolved', resolved_data = '{"native_name": "a"}'))

      assert :ok = Worker.run_now(bulk_action.id)
      assert %{status: :completed, progress_at_start: 1, stalled_starts: 0} = reload(bulk_action)
    end

    test "a start that finds the lock held writes nothing", ctx do
      bulk_action = submit!(ctx, 2)
      set!(bulk_action, "status = 'running', progress_at_start = 2, stalled_starts = 1")
      locker = lock_elsewhere(bulk_action.id)

      assert :busy = Worker.run_now(bulk_action.id)

      release(locker)
      assert %{progress_at_start: 2, stalled_starts: 1} = reload(bulk_action)
    end
  end

  describe "a row that kills its run" do
    test "per row: after three stalled starts, every row runs alone, and that row fails alone",
         ctx do
      bulk_action = submit!(ctx, 5, chunk_size: 5)
      kill_on_row(ctx, 3)
      isolations = collect([:ash_bulk_durable, :isolation, :start], bulk_action)
      crashed = collect([:ash_bulk_durable, :row, :crashed], bulk_action)

      # Starts 1 to 3 die in the one chunk, rolling it back, so nothing moves.
      for stalled <- 0..2 do
        assert :killed = attempt(bulk_action)
        assert %{stalled_starts: ^stalled} = reload(bulk_action)
        assert statuses(bulk_action) == List.duplicate(:resolved, 5)
        assert attempts(bulk_action) == [0, 0, 0, 0, 0]
      end

      assert isolations.() == []

      # Start 4 stalled out: rows run alone, each bumped before it runs, and
      # row 3's bump outlives its run.
      log = capture_log(fn -> assert :killed = attempt(bulk_action) end)
      assert log =~ "made no progress in its last 3 starts; running its rows one at a time"
      assert [{%{stalled_starts: 3}, %{mode: :per_row}}] = isolations.()
      assert %{stalled_starts: 3, isolating_row_id: isolating} = reload(bulk_action)
      assert statuses(bulk_action) == [:succeeded, :succeeded, :resolved, :resolved, :resolved]
      assert attempts(bulk_action) == [1, 1, 1, 0, 0]
      assert isolating == Enum.at(rows(bulk_action), 2).id

      # Start 5 made progress, so it runs chunks again, but row 3 first,
      # alone: it dies on it before the chunk of rows 4 and 5.
      assert :killed = attempt(bulk_action)
      assert %{stalled_starts: 0} = reload(bulk_action)
      assert statuses(bulk_action) == [:succeeded, :succeeded, :resolved, :resolved, :resolved]
      assert attempts(bulk_action) == [1, 1, 2, 0, 0]

      # Start 6 fails row 3 without running it, and runs the rest.
      log = capture_log(fn -> assert {:ran, :ok} = attempt(bulk_action) end)
      [_r1, _r2, r3, _r4, _r5] = rows(bulk_action)
      assert log =~ "row 2 (#{r3.id}) stopped the worker 2 times"
      assert [{%{attempts: 2}, %{row_id: row_id, row_index: 2}}] = crashed.()
      assert row_id == r3.id

      assert statuses(bulk_action) == [:succeeded, :succeeded, :failed, :succeeded, :succeeded]
      assert %{error: [%{error: %CrashedRowError{attempts: 2}} = stored]} = r3
      assert stored.message == "this row stopped the worker 2 times, so it was not run again"
      assert created(ctx) == codes(ctx, [1, 2, 4, 5])
      assert %{status: :completed_with_errors, rows_done: 4} = reload(bulk_action)

      # Five restarts after the first start.
      assert starts(bulk_action) == 6
    end

    test "phase 1: a resolver that kills its run fails its row the same way", ctx do
      bulk_action =
        submit_resolving!(ctx, [
          {EchoResolver, "a"},
          {KillingResolver, "b"},
          {EchoResolver, "c"}
        ])

      # Row 1 resolves, then 3 stalled starts, and 2 that die on row 2 alone:
      # the 7th fails it, and runs the rest.
      capture_log(fn -> assert run_until_finished(bulk_action) == 7 end)

      assert [
               %{status: :succeeded},
               %{status: :failed, attempts: 2, error: [%{error: %CrashedRowError{attempts: 2}}]},
               %{status: :succeeded}
             ] = rows(bulk_action)

      assert created(ctx) == codes(ctx, [1, 3])
      assert %{status: :completed_with_errors, rows_done: 2} = reload(bulk_action)
    end

    test "all or nothing: after three stalled starts it fails as crashed, its rows untouched",
         ctx do
      bulk_action = submit!(ctx, 2, mode: :all_or_nothing)
      kill_on_row(ctx, 2)

      for _start <- 1..3, do: assert(:killed = attempt(bulk_action))
      assert %{status: :running, stalled_starts: 2} = reload(bulk_action)

      log = capture_log(fn -> assert {:ran, :ok} = attempt(bulk_action) end)
      assert log =~ "failing it, as all or nothing has no row to run alone"

      assert %{status: :failed, result: %{"reason" => "crashed"}, stalled_starts: 3} =
               reload(bulk_action)

      assert statuses(bulk_action) == [:resolved, :resolved]
      assert attempts(bulk_action) == [0, 0]
      assert created(ctx) == []
    end
  end

  describe "suspect rows" do
    test "in a normal pass, a suspect runs alone before the chunks",
         ctx do
      bulk_action = submit!(ctx, 3, chunk_size: 3)
      [_r1, _r2, r3] = rows(bulk_action)
      # A run died while running row 3 alone.
      set_row!(r3, "attempts = 1")
      inserts = collect_inserts(ctx)

      assert :ok = Worker.run_now(bulk_action.id)

      assert inserts.() == Enum.map([3, 1, 2], &codes(ctx, [&1]))
      assert attempts(bulk_action) == [0, 0, 2]
      assert statuses(bulk_action) == [:succeeded, :succeeded, :succeeded]

      # Its run alone recorded how it went, and stopped naming it.
      assert %{status: :completed, stalled_starts: 0, isolating_row_id: nil} =
               reload(bulk_action)
    end
  end

  describe "a suspect resolved alone" do
    test "gives back only its own run's bump, so earlier deaths still count", ctx do
      bulk_action = submit_resolving!(ctx, [{EchoResolver, "a"}])
      [r1] = rows(bulk_action)
      # A run died on it in phase 2, and its resolution was lost since.
      set_row!(r1, "attempts = 1")
      kill_on_row(ctx, 1)

      # Resolved alone (bumped to 2, given back to 1), then run alone in
      # phase 2 (bumped to 2): it dies.
      assert :killed = attempt(bulk_action)
      assert [%{status: :resolved, attempts: 2}] = rows(bulk_action)

      # Two deaths in phase 2: it fails, not run again.
      capture_log(fn -> assert {:ran, :ok} = attempt(bulk_action) end)

      assert [%{status: :failed, attempts: 2, error: [%{error: %CrashedRowError{}}]}] =
               rows(bulk_action)

      assert %{status: :completed_with_errors} = reload(bulk_action)
    end
  end

  describe "a retry" do
    test "starts the count again", ctx do
      bulk_action = submit!(ctx, 2)
      assert :ok = Worker.run_now(bulk_action.id)
      [r1, r2] = rows(bulk_action)

      # As a bulk action that failed a row as crashed leaves it.
      set_row!(r2, "status = 'failed', attempts = 2")

      set!(
        bulk_action,
        "status = 'completed_with_errors', rows_done = 1, stalled_starts = 4, " <>
          "progress_at_start = 3, shutdown_stopped = true, isolating_row_id = $2",
        [Ecto.UUID.dump!(r2.id)]
      )

      set_row!(r1, "attempts = 1")

      assert {:ok, _retried} = Retry.retry(reload(bulk_action), scope: ctx.scope)

      assert %{
               status: :running,
               stalled_starts: 0,
               progress_at_start: nil,
               shutdown_stopped: false,
               isolating_row_id: nil
             } = reload(bulk_action)

      # The reopened row's attempts go; the one that succeeded keeps its own.
      assert [%{status: :succeeded, attempts: 1}, %{status: :resolved, attempts: 0}] =
               rows(bulk_action)
    end
  end

  describe "giving a bump back" do
    test "a shutdown after a suspect resolved alone, while the run goes on, leaves its attempts",
         ctx do
      bulk_action = submit_resolving!(ctx, [{EchoResolver, "a"}, {KillingResolver, "b"}])
      [r1, _r2] = rows(bulk_action)
      # A run died on row 1 once, while running it alone.
      set_row!(r1, "attempts = 1")

      # Row 1 resolves alone, bumped and given back, which ends its isolation;
      # then row 2 stops the run as it resolves with the rest.
      assert :killed = attempt(bulk_action)
      assert [%{status: :resolved, attempts: 1}, %{status: :pending}] = rows(bulk_action)
      assert %{isolating_row_id: nil} = reload(bulk_action)

      # As if the poller's shutdown had stopped that run.
      set!(bulk_action, "shutdown_stopped = true")
      assert :killed = attempt(bulk_action)

      # Its bump was given back once already, so its earlier death still counts.
      assert [%{status: :resolved, attempts: 1}, _r2] = rows(bulk_action)
    end

    test "a shutdown's give-back never takes a row below 0", ctx do
      bulk_action = submit!(ctx, 1)
      [r1] = rows(bulk_action)

      # A shutdown stopped the last run while it named row 1, whose bump is
      # already gone.
      set!(bulk_action, "status = 'running', shutdown_stopped = true, isolating_row_id = $2", [
        Ecto.UUID.dump!(r1.id)
      ])

      assert {:ran, :ok} = attempt(bulk_action)
      assert [%{status: :succeeded, attempts: 0}] = rows(bulk_action)
      assert %{status: :completed} = reload(bulk_action)
    end

    test "a resolve's give-back takes one from the committed count, never going below 0", ctx do
      bulk_action = submit_resolving!(ctx, [{ResettingResolver, ctx.user.id}])
      [r1] = rows(bulk_action)
      # A suspect: bumped to 2 to resolve alone, its bumps taken back meanwhile.
      set_row!(r1, "attempts = 1")

      assert {:ran, :ok} = attempt(bulk_action)

      # No attempts left, so it ran with the rest in phase 2.
      assert [%{status: :succeeded, attempts: 0}] = rows(bulk_action)
      assert %{status: :completed} = reload(bulk_action)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp submit!(ctx, count, opts \\ []) do
    inputs =
      Enum.map(1..count, fn i ->
        %{code: "#{ctx.tag}-#{i}", name: "#{ctx.tag} N#{i}", native_name: "#{ctx.tag} A#{i}"}
      end)

    {:ok, bulk_action} =
      AshBulkDurable.bulk_create(
        inputs,
        Region,
        :create,
        Keyword.merge([scope: ctx.scope, chunk_size: 1], opts)
      )

    bulk_action
  end

  # One row a resolver for each, resolving the row's native name.
  defp submit_resolving!(ctx, resolvers) do
    rows =
      resolvers
      |> Enum.with_index(1)
      |> Enum.map(fn {{resolver, value}, i} ->
        %{
          input: %{
            code: "#{ctx.tag}-#{i}",
            name: "#{ctx.tag} N#{i}",
            native_name: {:resolve, resolver, value}
          }
        }
      end)

    Ash.create!(
      BulkAction,
      %{
        user_id: ctx.user.id,
        resource_name: inspect(Region),
        action_name: :create,
        action_type: :create,
        total_rows: length(rows),
        mode: :per_row,
        chunk_size: 1,
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  # Kills the run writing the region of row `i`, inside the transaction
  # that writes it, which then commits nothing.
  defp kill_on_row(ctx, i) do
    code = "#{ctx.tag}-#{i}"

    attach([:ash_bulk_durable, :test, :repo, :query], fn _measurements, metadata ->
      if metadata.source == "regions" and String.starts_with?(metadata.query, "INSERT") and
           code in List.flatten(metadata.params),
         do: Process.exit(self(), :kill)
    end)
  end

  # The codes in each insert of the bulk action's regions, in order.
  defp collect_inserts(ctx) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    attach([:ash_bulk_durable, :test, :repo, :query], fn _measurements, metadata ->
      case inserted_codes(ctx, metadata) do
        [] -> :ok
        codes -> Agent.update(agent, &[codes | &1])
      end
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() end
  end

  defp inserted_codes(ctx, %{source: "regions", query: "INSERT" <> _, params: params}) do
    params
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, ctx.tag <> "-")))
    |> Enum.sort()
  end

  defp inserted_codes(_ctx, _metadata), do: []

  # The bulk action's `event`s, as `{measurements, metadata}`, in order.
  defp collect(event, bulk_action) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    attach(event, fn measurements, metadata ->
      if metadata.bulk_action_id == bulk_action.id,
        do: Agent.update(agent, &[{measurements, metadata} | &1])
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() end
  end

  @doc false
  def handle(_event, measurements, metadata, fun), do: fun.(measurements, metadata)

  defp attach(event, fun) do
    handler = "crash-test-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, &__MODULE__.handle/4, fun)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # One start of the bulk action, in a process of its own, as a poller's
  # would be: `:killed` when it died, `{:ran, result}` when it returned. A
  # killed run's lock goes with its connection, so it waits for that.
  defp attempt(bulk_action) do
    Process.put(:starts, Process.get(:starts, 0) + 1)

    {pid, monitor} =
      spawn_monitor(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        exit({:ran, Worker.run_now(bulk_action.id)})
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 10_000
    if reason == :killed, do: assert(eventually(fn -> lockable?(bulk_action.id) end))
    reason
  end

  defp starts(_bulk_action), do: Process.get(:starts, 0)

  # Starts the bulk action until it is finished, and returns how many starts
  # that took.
  defp run_until_finished(bulk_action, limit \\ 20) do
    Enum.reduce_while(1..limit, 0, fn start, _starts ->
      attempt(bulk_action)

      if reload(bulk_action).status in [:queued, :running],
        do: {:cont, start},
        else: {:halt, start}
    end)
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp statuses(bulk_action), do: Enum.map(rows(bulk_action), & &1.status)
  defp attempts(bulk_action), do: Enum.map(rows(bulk_action), & &1.attempts)

  defp reload(bulk_action), do: Ash.get!(BulkAction, bulk_action.id, authorize?: false)

  defp set!(bulk_action, set, params \\ []) do
    Repo.query!(
      "UPDATE bulk_actions SET #{set} WHERE id = $1",
      [Ecto.UUID.dump!(bulk_action.id) | params]
    )
  end

  defp set_row!(row, set) do
    Repo.query!("UPDATE bulk_action_rows SET #{set} WHERE id = $1", [Ecto.UUID.dump!(row.id)])
  end

  # The codes of the regions the bulk action created.
  defp created(ctx) do
    %{rows: rows} = Repo.query!("SELECT code FROM regions WHERE code LIKE $1 || '-%'", [ctx.tag])
    rows |> List.flatten() |> Enum.sort()
  end

  defp codes(ctx, indexes), do: Enum.map(indexes, &"#{ctx.tag}-#{&1}")

  # Holds the bulk action's row lock from a connection of its own until told.
  defp lock_elsewhere(id) do
    test_pid = self()

    pid =
      spawn(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM bulk_actions WHERE id = $1 FOR NO KEY UPDATE", [
            Ecto.UUID.dump!(id)
          ])

          send(test_pid, :locked)

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end)

        send(test_pid, :released)
      end)

    assert_receive :locked, 2_000
    pid
  end

  defp release(locker) do
    send(locker, :release)
    assert_receive :released, 2_000
  end

  defp lockable?(id) do
    {:ok, locked} =
      Repo.transaction(fn ->
        Repo.query!("SELECT 1 FROM bulk_actions WHERE id = $1 FOR NO KEY UPDATE SKIP LOCKED", [
          Ecto.UUID.dump!(id)
        ]).num_rows == 1
      end)

    locked
  end

  defp eventually(fun, tries \\ 250) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp create_user!(tag) do
    Ash.create!(User, %{name: "Crash", email: "#{tag}@example.test"},
      action: :create_super,
      authorize?: false
    )
  end

  # Every user the test made has an email ending in its tag, and every region
  # a code starting with it.
  defp cleanup(tag) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    users = "SELECT id FROM users WHERE email LIKE '%' || $1"
    email = "#{tag}@example.test"

    Repo.query!("DELETE FROM bulk_actions WHERE user_id IN (#{users})", [email])
    Repo.query!("DELETE FROM regions WHERE code LIKE $1 || '-%'", [tag])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [email])
  end
end
