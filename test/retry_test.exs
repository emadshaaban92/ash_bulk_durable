defmodule AshBulkDurable.RetryTest do
  @moduledoc """
  `AshBulkDurable.retry/2` and `retry_row/2` as a script calls them, the
  real worker running each bulk action and each retry: every shape a retry
  takes, in both modes, and what is refused. `/bulk` reaches `retry/3` with a
  corrected sheet (the example's `/bulk` page tests).
  """
  use AshBulkDurable.DataCase, async: true
  use Oban.Testing, repo: AshBulkDurable.Test.Repo

  require Ash.Query

  defmodule RefusingResolver do
    @moduledoc "Fails the row holding the reference."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_args, nil, _context), do: {:error, "refused"}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule UnpreparableResolver do
    @moduledoc "Ends the bulk action `:failed` at the chunk holding the reference."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:error, :unprepared}

    @impl true
    def resolve(_args, _state, _context), do: {:error, :never}

    @impl true
    def finish(_state), do: :ok
  end

  alias AshBulkDurable.Core.Worker
  alias AshBulkDurable.Test.{BulkAction, Row}
  alias AshBulkDurable.Test.Branch
  alias AshBulkDurable.Test.Region
  alias AshBulkDurable.Test.RoleTestHelpers

  setup %{super_user: user} do
    %{user: user, scope: AshBulkDurable.Test.Scope.new(actor: user)}
  end

  defp tag, do: "F#{System.unique_integer([:positive])}"

  defp region_input(tag \\ tag()),
    do: %{code: tag, name: "Region #{tag}", native_name: "منطقة #{tag}"}

  defp create_region!(user), do: Ash.create!(Region, region_input(), actor: user)

  defp create_branches!(count, user) do
    Enum.map(1..count, fn _n ->
      Ash.create!(Branch, %{name: "Branch #{System.unique_integer([:positive])}"}, actor: user)
    end)
  end

  defp lookup(code), do: {:lookup, Region, :code, code}

  defp run!(bulk_action) do
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
    {reload(bulk_action), rows(bulk_action)}
  end

  defp reload(bulk_action), do: Ash.get!(BulkAction, bulk_action.id, authorize?: false)

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp region_id(branch, user), do: Ash.reload!(branch, actor: user).region_id

  # An old attempt Oban still has, as one that raised after the bulk action
  # finished leaves it.
  defp old_job(%{oban_job_id: job_id}),
    do: %{AshBulkDurable.Test.Repo.get!(Oban.Job, job_id) | attempt: 2}

  defp jobs(bulk_action),
    do: length(all_enqueued(worker: Worker, args: %{bulk_action_id: bulk_action.id}))

  defp codes_written(codes) do
    Region
    |> Ash.Query.filter(code in ^codes)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&to_string(&1.code))
    |> Enum.sort()
  end

  # Two failed rows, each for a region whose code is already taken.
  defp two_failed!(ctx) do
    [first, second] = Enum.map(1..2, fn _n -> region_input() end)
    Enum.each([first, second], &Ash.create!(Region, &1, actor: ctx.user))
    good = region_input()

    {:ok, bulk_action} =
      AshBulkDurable.bulk_create([first, good, second], Region, :create, scope: ctx.scope)

    {bulk_action, rows} = run!(bulk_action)
    assert bulk_action.status == :completed_with_errors
    [failed_first, _good, failed_second] = rows
    %{bulk_action: bulk_action, first: failed_first, second: failed_second}
  end

  # Two rows that found their region and then failed on the unique name,
  # that region's code changing after: a row resolving it again finds
  # nothing, so only one that kept what it found can still succeed.
  defp two_failed_past_lookup!(ctx) do
    [branch, other] = create_branches!(2, ctx.user)
    [taken] = create_branches!(1, ctx.user)
    found = create_region!(ctx.user)
    code = to_string(found.code)
    input = %{name: taken.name, region_id: lookup(code)}

    {:ok, bulk_action} =
      AshBulkDurable.update_many([{branch, input}, {other, input}], Branch, :update,
        scope: ctx.scope
      )

    {bulk_action, [kept, moved]} = run!(bulk_action)
    assert Enum.map([kept, moved], & &1.status) == [:failed, :failed]
    assert Enum.map([kept, moved], & &1.resolved_data["region_id"]) == [found.id, found.id]

    Ash.update!(found, %{code: tag()}, actor: ctx.user)

    %{
      bulk_action: bulk_action,
      branch: branch,
      other: other,
      kept: kept,
      moved: moved,
      found: found,
      kept_input: %{name: "Branch #{tag()}", region_id: lookup(code)}
    }
  end

  test "a late attempt of the job a retry replaced drives nothing; the retry's own job does",
       ctx do
    failed = two_failed!(ctx)
    superseded = old_job(failed.bulk_action)

    {:ok, retried} = AshBulkDurable.retry(failed.bulk_action, scope: ctx.scope)
    assert retried.oban_job_id != superseded.id

    assert :ok = perform_job(superseded, repo: AshBulkDurable.Test.Repo)

    assert reload(retried).status == :running

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
    assert reload(retried).status == :completed_with_errors
  end

  describe "retry/2, per row" do
    test "as it is: what failed the row is fixed elsewhere, and the row runs with the shared input",
         ctx do
      [branch, other] = create_branches!(2, ctx.user)
      code = tag()

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([branch, other], :update, %{region_id: lookup(code)},
          scope: ctx.scope
        )

      {bulk_action, rows} = run!(bulk_action)
      assert bulk_action.status == :completed_with_errors
      assert Enum.map(rows, & &1.status) == [:failed, :failed]

      region = Ash.create!(Region, region_input(code), actor: ctx.user)

      assert {:ok, %{status: :running}} = AshBulkDurable.retry(bulk_action, scope: ctx.scope)
      {bulk_action, rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.rows_done == 2
      assert Enum.map(rows, & &1.input) == [nil, nil]
      assert region_id(branch, ctx.user) == region.id
      assert region_id(other, ctx.user) == region.id
    end

    test "a new shared input resolves again; a row with its own input keeps it", ctx do
      [branch, other] = create_branches!(2, ctx.user)
      [shared, own] = [create_region!(ctx.user), create_region!(ctx.user)]

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([branch, other], :update, %{region_id: lookup(tag())},
          scope: ctx.scope
        )

      {bulk_action, [branch_row, _other_row]} = run!(bulk_action)

      assert {:ok, _retried} =
               AshBulkDurable.retry(bulk_action,
                 input: %{region_id: lookup(shared.code)},
                 rows: %{branch_row.id => %{input: %{region_id: lookup(own.code)}}},
                 scope: ctx.scope
               )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.input == %{region_id: lookup(shared.code)}
      assert region_id(branch, ctx.user) == own.id
      assert region_id(other, ctx.user) == shared.id
    end

    test "a row keeps what the shared input resolved to only while that input stands", ctx do
      [branch, other] = create_branches!(2, ctx.user)
      [old, new] = [create_region!(ctx.user), create_region!(ctx.user)]
      name = "Branch #{tag()}"

      # Both resolve the lookup; the second then fails on the unique name.
      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(
          [branch, other],
          :update,
          %{name: name, region_id: lookup(old.code)},
          scope: ctx.scope
        )

      {bulk_action, [_written, failed]} = run!(bulk_action)
      assert failed.status == :failed
      assert failed.resolved_data["region_id"] == old.id

      {:ok, _retried} =
        AshBulkDurable.retry(bulk_action,
          input: %{name: "Branch #{tag()}", region_id: lookup(new.code)},
          scope: ctx.scope
        )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert region_id(branch, ctx.user) == old.id
      assert region_id(other, ctx.user) == new.id
    end

    test "a correction keeps what an unchanged reference found and looks up a changed one",
         ctx do
      failed = two_failed_past_lookup!(ctx)
      elsewhere = create_region!(ctx.user)

      {:ok, _retried} =
        AshBulkDurable.retry(failed.bulk_action,
          rows: %{
            failed.kept.id => %{input: failed.kept_input},
            failed.moved.id => %{
              input: %{name: "Branch #{tag()}", region_id: lookup(elsewhere.code)}
            }
          },
          scope: ctx.scope
        )

      {bulk_action, _rows} = run!(failed.bulk_action)

      assert bulk_action.status == :completed
      assert region_id(failed.branch, ctx.user) == failed.found.id
      assert region_id(failed.other, ctx.user) == elsewhere.id
    end

    test "a per-row correction fixes its row; the rows it leaves out run too and fail again",
         ctx do
      %{bulk_action: bulk_action, first: first} = two_failed!(ctx)
      fixed = region_input()

      {:ok, _retried} =
        AshBulkDurable.retry(bulk_action, rows: %{first.id => %{input: fixed}}, scope: ctx.scope)

      {bulk_action, [first, _good, second]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert bulk_action.rows_done == 2
      assert first.status == :succeeded
      assert second.status == :failed
      assert second.error != nil
      assert codes_written([fixed.code]) == [fixed.code]
    end

    test "a correction changes the lookup of a row found by an identity", ctx do
      region = create_region!(ctx.user)
      name = "Renamed #{tag()}"

      {:ok, bulk_action} =
        AshBulkDurable.update_many([{%{code: tag()}, %{name: name}}], Region, :update,
          identity: :code,
          scope: ctx.scope
        )

      {bulk_action, [row]} = run!(bulk_action)
      assert row.status == :failed

      {:ok, _retried} =
        AshBulkDurable.retry(bulk_action,
          rows: %{row.id => %{lookup: %{code: region.code}}},
          scope: ctx.scope
        )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert Ash.reload!(region, actor: ctx.user).name == name
    end

    test "the bulk action its last retry returned retries again, its correction running", ctx do
      taken = region_input()
      Ash.create!(Region, taken, actor: ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([taken], Region, :create, scope: ctx.scope)

      {_bulk_action, [row]} = run!(bulk_action)

      {:ok, retried} = AshBulkDurable.retry(bulk_action, scope: ctx.scope)
      assert retried.status == :running

      {_bulk_action, [%{status: :failed}]} = run!(bulk_action)

      fixed = region_input()

      assert {:ok, again} =
               AshBulkDurable.retry(retried,
                 rows: %{row.id => %{input: fixed}},
                 scope: ctx.scope
               )

      assert again.status == :running

      {bulk_action, [row]} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert row.status == :succeeded
      assert codes_written([fixed.code]) == [fixed.code]
    end

    test "a selected record stays the record selected, gone or not", ctx do
      [kept, gone, other] = create_branches!(3, ctx.user)
      region = create_region!(ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(
          [kept, gone],
          :update,
          %{region_id: lookup(region.code)},
          scope: ctx.scope
        )

      Ash.destroy!(gone, actor: ctx.user)
      {bulk_action, [_kept, failed]} = run!(bulk_action)
      assert failed.status == :failed

      assert_raise ArgumentError, ~r/its record stays the same/, fn ->
        AshBulkDurable.retry(bulk_action,
          rows: %{failed.id => %{lookup: %{id: other.id}}},
          scope: ctx.scope
        )
      end

      assert reload(bulk_action).status == :completed_with_errors
      assert Ash.get!(Row, failed.id, authorize?: false).status == :failed
    end

    test "a row that is not one left to run refuses the whole retry", ctx do
      %{bulk_action: bulk_action, first: first} = two_failed!(ctx)
      [_first, succeeded, _second] = rows(bulk_action)
      jobs_before = jobs(bulk_action)

      for unmatched <- [Ecto.UUID.generate(), succeeded.id] do
        assert {:error, %{unmatched: [^unmatched]}} =
                 AshBulkDurable.retry(bulk_action,
                   rows: %{first.id => %{input: region_input()}, unmatched => %{}},
                   scope: ctx.scope
                 )
      end

      assert reload(bulk_action).status == :completed_with_errors
      assert Ash.get!(Row, first.id, authorize?: false).status == :failed
      assert jobs(bulk_action) == jobs_before
    end
  end

  describe "retry/2, all or nothing" do
    test "a rollback is corrected in the row that caused it, and every row runs again", ctx do
      taken = region_input()
      Ash.create!(Region, taken, actor: ctx.user)
      good = region_input()

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([good, taken], Region, :create,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      {bulk_action, [_good, offending]} = run!(bulk_action)

      assert bulk_action.status == :failed
      assert bulk_action.result["reason"] == "atomic_chunk_rolled_back"
      assert codes_written([good.code]) == []

      fixed = region_input()

      assert {:ok, retried} =
               AshBulkDurable.retry(bulk_action,
                 rows: %{offending.id => %{input: fixed}},
                 scope: ctx.scope
               )

      assert retried.status == :running
      assert retried.error == nil
      assert retried.result == nil
      assert retried.finished_at == nil

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.rows_done == 2
      assert codes_written([good.code, fixed.code]) == Enum.sort([good.code, fixed.code])
    end

    test "a failed lookup stops it before anything is written, and it retries as it is", ctx do
      [branch] = create_branches!(1, ctx.user)
      code = tag()

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([branch], :update, %{region_id: lookup(code)},
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      {bulk_action, _rows} = run!(bulk_action)
      assert bulk_action.result["reason"] == "atomic_phase1_failed"

      region = Ash.create!(Region, region_input(code), actor: ctx.user)

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, scope: ctx.scope)
      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert region_id(branch, ctx.user) == region.id
    end

    test "a record its lookup can't find is named as the row that stopped it", ctx do
      found = Ash.create!(Region, region_input(), actor: ctx.user)
      missing = region_input()
      renamed = "Renamed #{tag()}"

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [{%{code: found.code}, %{name: renamed}}, {%{code: missing.code}, %{name: tag()}}],
          Region,
          :update,
          identity: :code,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.result["reason"] == "atomic_chunk_rolled_back"
      assert bulk_action.result["row_index"] == 1
      assert [%{error: %Ash.Error.Query.NotFound{}}] = bulk_action.error

      Ash.create!(Region, missing, actor: ctx.user)
      {:ok, _retried} = AshBulkDurable.retry(bulk_action, scope: ctx.scope)
      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert Ash.reload!(found, actor: ctx.user).name == renamed
    end

    test "it cannot be retried while its owner has another unresolved one", ctx do
      {:ok, failed} =
        AshBulkDurable.bulk_create([%{code: tag()}], Region, :create,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      {failed, _rows} = run!(failed)
      assert failed.status == :failed

      {:ok, _unresolved} =
        AshBulkDurable.bulk_create([region_input()], Region, :create, scope: ctx.scope)

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry(failed, scope: ctx.scope)
      assert reload(failed).status == :failed
    end
  end

  describe "retry with a shared input" do
    # Another tab's retry moved the shared input on: what this caller holds
    # is older than what the rows last ran with.
    test "a stale bulk action cannot keep a resolution of an input it never saw", ctx do
      [branch] = create_branches!(1, ctx.user)
      [taken] = create_branches!(1, ctx.user)
      [first, second] = [create_region!(ctx.user), create_region!(ctx.user)]

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(
          [branch],
          :update,
          %{name: taken.name, region_id: lookup(first.code)},
          scope: ctx.scope
        )

      {stale, _rows} = run!(bulk_action)

      {:ok, _retried} =
        AshBulkDurable.retry(stale,
          input: %{name: taken.name, region_id: lookup(second.code)},
          scope: ctx.scope
        )

      {_parked, [row]} = run!(bulk_action)
      assert row.resolved_data["region_id"] == second.id

      {:ok, _retried} =
        AshBulkDurable.retry(stale,
          input: %{name: "Branch #{tag()}", region_id: lookup(first.code)},
          scope: ctx.scope
        )

      {finished, _rows} = run!(bulk_action)

      assert finished.status == :completed
      assert region_id(branch, ctx.user) == first.id
    end

    test "reads the bulk action once, however many rows reopen", ctx do
      %{bulk_action: bulk_action} = two_failed!(ctx)
      test_pid = self()
      handler = "retry-selects-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :test, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == test_pid and source == "bulk_actions" and
               String.starts_with?(query, "SELECT") do
            send(test_pid, :bulk_action_read)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, scope: ctx.scope)

      assert_received :bulk_action_read
      refute_received :bulk_action_read
    end
  end

  describe "retry_row/2" do
    test "is refused while rows the bulk action never reached remain", ctx do
      [first, second, third] = inputs = Enum.map(1..3, fn _n -> region_input() end)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(
          [
            %{first | name: {:resolve, RefusingResolver, "first"}},
            %{second | name: {:resolve, UnpreparableResolver, "second"}},
            third
          ],
          Region,
          :create,
          scope: ctx.scope,
          chunk_size: 1
        )

      {failed, [refused, unprepared, untouched]} = run!(bulk_action)

      assert failed.status == :failed

      assert Enum.map([refused, unprepared, untouched], & &1.status) ==
               [:failed, :pending, :resolved]

      jobs_before = jobs(bulk_action)

      assert {:error, %{unprocessed: 2}} =
               AshBulkDurable.retry_row(refused, input: first, scope: ctx.scope)

      assert jobs(bulk_action) == jobs_before
      assert reload(bulk_action).status == :failed
      assert codes_written(Enum.map(inputs, & &1.code)) == []

      # `retry` is what resumes them, the correction riding along.
      {:ok, _retried} =
        AshBulkDurable.retry(failed,
          rows: %{refused.id => %{input: first}, unprepared.id => %{input: second}},
          scope: ctx.scope
        )

      {finished, _rows} = run!(bulk_action)

      assert finished.status == :completed
      assert codes_written(Enum.map(inputs, & &1.code)) == Enum.sort(Enum.map(inputs, & &1.code))
    end

    test "reruns one row alone; the last one finishes the bulk action", ctx do
      %{bulk_action: bulk_action, first: first, second: second} = two_failed!(ctx)
      fixed = region_input()

      assert {:ok, %{status: :running}} =
               AshBulkDurable.retry_row(first, input: fixed, scope: ctx.scope)

      {bulk_action, [first_after, _good, second_after]} = run!(bulk_action)

      assert first_after.status == :succeeded
      assert second_after.status == :failed
      assert second_after.error == second.error
      assert second_after.input == second.input
      assert bulk_action.status == :completed_with_errors
      assert bulk_action.rows_done == 2

      other = region_input()
      {:ok, _retried} = AshBulkDurable.retry_row(second, input: other, scope: ctx.scope)
      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert codes_written([fixed.code, other.code]) == Enum.sort([fixed.code, other.code])
    end

    test "a row that failed again keeps its correction and the new error", ctx do
      %{bulk_action: bulk_action, first: first} = two_failed!(ctx)
      invalid = Map.delete(region_input(), :name)

      {:ok, _retried} = AshBulkDurable.retry_row(first, input: invalid, scope: ctx.scope)
      {bulk_action, [first_after | _rows]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert first_after.status == :failed
      assert first_after.input == invalid
      refute first_after.error == first.error
    end

    test "a correction keeps what an unchanged reference found and looks up a changed one",
         ctx do
      failed = two_failed_past_lookup!(ctx)
      elsewhere = create_region!(ctx.user)

      {:ok, _retried} =
        AshBulkDurable.retry_row(failed.kept, input: failed.kept_input, scope: ctx.scope)

      {bulk_action, _rows} = run!(failed.bulk_action)
      assert bulk_action.status == :completed_with_errors
      assert region_id(failed.branch, ctx.user) == failed.found.id

      {:ok, _retried} =
        AshBulkDurable.retry_row(failed.moved,
          input: %{name: "Branch #{tag()}", region_id: lookup(elsewhere.code)},
          scope: ctx.scope
        )

      {bulk_action, _rows} = run!(bulk_action)
      assert bulk_action.status == :completed
      assert region_id(failed.other, ctx.user) == elsewhere.id
    end

    test "a row no longer failed has nothing to retry", ctx do
      %{bulk_action: bulk_action} = two_failed!(ctx)
      [_first, succeeded, _second] = rows(bulk_action)
      id = succeeded.id

      assert {:error, %{unmatched: [^id]}} =
               AshBulkDurable.retry_row(succeeded, scope: ctx.scope)

      assert reload(bulk_action).status == :completed_with_errors
    end

    test "an all-or-nothing bulk action retries whole", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([%{code: tag()}], Region, :create,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      {_bulk_action, [row]} = run!(bulk_action)

      assert_raise ArgumentError, ~r/retries whole/, fn ->
        AshBulkDurable.retry_row(row, scope: ctx.scope)
      end
    end
  end

  describe "refused" do
    test "a row that succeeded since it was read keeps its one run", ctx do
      [branch, other] = create_branches!(2, ctx.user)
      [taken] = create_branches!(1, ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [{branch, %{name: taken.name}}, {other, %{name: taken.name}}],
          Branch,
          :update,
          scope: ctx.scope
        )

      {parked, [read_by_the_other_tab, second]} = run!(bulk_action)
      name = "Branch #{tag()}"

      {:ok, _retried} =
        AshBulkDurable.retry(parked,
          rows: %{read_by_the_other_tab.id => %{input: %{name: name}}},
          scope: ctx.scope
        )

      {parked, [succeeded, _second]} = run!(bulk_action)
      assert succeeded.status == :succeeded
      assert parked.rows_done == 1

      # `retry` read its rows before its transaction, with no way in between
      # for a test to reach: this is the write that tab goes on to make.
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               Ash.update(read_by_the_other_tab, %{input: %{name: "Branch #{tag()}"}},
                 action: :reopen_with_corrections,
                 authorize?: false
               )

      {:ok, _retried} =
        AshBulkDurable.retry(parked,
          rows: %{second.id => %{input: %{name: "Branch #{tag()}"}}},
          scope: ctx.scope
        )

      {finished, _rows} = run!(bulk_action)

      assert finished.status == :completed
      assert finished.rows_done == finished.total_rows
      assert Ash.reload!(branch, actor: ctx.user).name == name
    end

    test "when what it ran is gone, nothing written", ctx do
      for {column, name} <- [
            {"resource_name", "MyApp.NoLongerHere"},
            {"action_name", "promote_to_super"},
            {"action_name", "gone_#{System.unique_integer([:positive])}"}
          ] do
        %{bulk_action: bulk_action, first: first, second: second} = two_failed!(ctx)

        AshBulkDurable.Test.Repo.query!("UPDATE bulk_actions SET #{column} = $1 WHERE id = $2", [
          name,
          Ecto.UUID.dump!(bulk_action.id)
        ])

        gone = reload(bulk_action)
        jobs_before = jobs(bulk_action)
        sheet = %AshBulkDurable.Sheet{headers: ["row_id"], rows: [%{"row_id" => first.id}]}

        assert {:error, :gone} = AshBulkDurable.retry(gone, scope: ctx.scope)
        assert {:error, :gone} = AshBulkDurable.retry(gone, sheet, scope: ctx.scope)
        assert {:error, :gone} = AshBulkDurable.retry_row(first, scope: ctx.scope)

        assert jobs(bulk_action) == jobs_before
        assert reload(bulk_action).status == :completed_with_errors
        assert Ash.get!(Row, second.id, authorize?: false).status == :failed

        {:ok, _abandoned} = AshBulkDurable.abandon(gone, scope: ctx.scope)
      end
    end

    test "while it is running, even held as a stale record", ctx do
      %{bulk_action: bulk_action, first: first, second: second} = two_failed!(ctx)

      {:ok, running} = AshBulkDurable.retry_row(first, scope: ctx.scope)
      assert running.status == :running
      jobs_before = jobs(bulk_action)

      # `running` reads :running, `bulk_action` the state it was retried from.
      for held <- [running, bulk_action] do
        assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry(held, scope: ctx.scope)
      end

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry_row(second, scope: ctx.scope)

      assert jobs(bulk_action) == jobs_before
      assert Ash.get!(Row, second.id, authorize?: false).status == :failed
    end

    test "while it is queued", ctx do
      {:ok, queued} =
        AshBulkDurable.bulk_create([region_input()], Region, :create, scope: ctx.scope)

      assert queued.status == :queued
      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry(queued, scope: ctx.scope)
      assert reload(queued).status == :queued
    end

    test "once completed: nothing is left to run", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([region_input()], Region, :create, scope: ctx.scope)

      {bulk_action, _rows} = run!(bulk_action)
      assert bulk_action.status == :completed

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry(bulk_action, scope: ctx.scope)
    end

    test "once abandoned, for good", ctx do
      %{bulk_action: bulk_action, first: first} = two_failed!(ctx)
      {:ok, abandoned} = AshBulkDurable.abandon(bulk_action, scope: ctx.scope)

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry(abandoned, scope: ctx.scope)
      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry_row(first, scope: ctx.scope)

      assert reload(bulk_action).status == :cancelled
      assert Ash.get!(Row, first.id, authorize?: false).status == :failed
    end

    test "for anyone but its owner", ctx do
      %{bulk_action: bulk_action, first: first} = two_failed!(ctx)

      stranger =
        AshBulkDurable.Test.Scope.new(
          actor: RoleTestHelpers.create_user_with_platform_role(ctx.user, :platform_admin)
        )

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry(bulk_action, scope: stranger)
      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.retry_row(first, scope: stranger)

      sheet = AshBulkDurable.errors_sheet(bulk_action)
      name = "Stranger #{tag()}"
      corrected = %{sheet | rows: Enum.map(sheet.rows, &%{&1 | "name" => name})}

      assert {:error, %Ash.Error.Invalid{}} =
               AshBulkDurable.retry(bulk_action, corrected, scope: stranger)

      assert reload(bulk_action).status == :completed_with_errors
      assert Ash.get!(Row, first.id, authorize?: false).status == :failed
      assert Ash.get!(Row, first.id, authorize?: false).input == first.input
    end
  end
end
