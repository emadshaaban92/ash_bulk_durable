defmodule AshBulkDurable.Core.WorkerTest do
  @moduledoc """
  Tests for `AshBulkDurable.Core.Worker` driving the two-phase
  pipeline. Each scenario uses `Oban.Testing.perform_job/3` so the
  worker runs synchronously inside the test sandbox.

  `async: false` because tests swap `:ash_bulk_durable` config (storage
  adapter, `:test_poison`) globally and drive the
  `AshBulkDurable.TestStorage` named Agent (a VM-wide singleton).
  """
  use AshBulkDurable.DataCase, async: false
  use Oban.Testing, repo: AshBulkDurable.Test.Repo

  import AshBulkDurable.StorageHelpers

  require Ash.Query

  import ExUnit.CaptureLog

  alias AshBulkDurable.Core.{StagedFileError, Worker}
  alias AshBulkDurable.Test.{BulkAction, Row}
  alias AshBulkDurable.Test.Region

  @region_resource_name "AshBulkDurable.Test.Region"

  # ── Test-only resolvers ───────────────────────────────────────────────

  defmodule RaiseOnRecoveryResolver do
    @moduledoc """
    Resolves a value to itself. Once the poison value in `:test_poison` is
    written, `after_write/3` first refuses it (so the chunk fails
    non-raisingly and the worker drops into row-by-row recovery), then
    raises on the recovery attempt. A `Process.put` counter scopes the "second call" tracking
    to the Oban perform process (the test process under
    `Oban.Testing.perform_job/3`).
    """
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context), do: {:ok, value}

    @impl true
    def finish(nil), do: :ok

    @impl true
    def after_write(_record, resolved, _context) do
      if resolved == Application.get_env(:ash_bulk_durable, :test_poison) do
        count = Process.get({__MODULE__, resolved}, 0)
        Process.put({__MODULE__, resolved}, count + 1)

        if count == 0,
          do:
            {:error,
             Ash.Error.Changes.InvalidAttribute.exception(
               field: :native_name,
               message: "first attempt fail"
             )},
          else: raise("test_recovery_raise")
      else
        :ok
      end
    end
  end

  defmodule RaisingResolver do
    @moduledoc """
    Raises on the poison value, in the phase `:test_raise_in` names.
    """
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context) do
      if poison?(value, :resolve), do: raise("test_resolve_raise")
      {:ok, value}
    end

    @impl true
    def finish(nil), do: :ok

    @impl true
    def after_write(_record, value, _context) do
      if poison?(value, :write), do: raise("test_write_raise")

      :ok
    end

    defp poison?(value, phase) do
      value == Application.get_env(:ash_bulk_durable, :test_poison) and
        phase == Application.get_env(:ash_bulk_durable, :test_raise_in)
    end
  end

  defmodule PoisonResolver do
    @moduledoc """
    Errors when the value matches the poison string configured in
    `:ash_bulk_durable` app env; otherwise resolves to the value as-is so
    phase 2 can apply. Reads from app env (not Process dict) so children
    spawned by phase-1's `Task.async_stream` see the same value.
    """
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context) do
      case Application.get_env(:ash_bulk_durable, :test_poison) do
        ^value -> {:error, :poison_match}
        _ -> {:ok, value}
      end
    end

    @impl true
    def finish(nil), do: :ok
  end

  defmodule NoMatchResolver do
    @moduledoc "Finds nothing for any reference, as the callback allows."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_args, nil, _context), do: {:error, :not_found}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule MovingResolver do
    @moduledoc """
    Resolves a value to itself, and the first time it resolves after
    `hook/1`, runs the hook first: a test steps in as another run between
    this run reading its `:pending` rows and flipping them. Kept in
    `:persistent_term`, since phase 1 resolves in its own tasks.
    """
    @behaviour AshBulkDurable.Core.Resolver

    @key {__MODULE__, :hook}

    def hook(fun), do: :persistent_term.put(@key, fun)
    def clear, do: :persistent_term.erase(@key)

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context) do
      # `erase/1` is true for one caller only.
      with fun when is_function(fun, 0) <- :persistent_term.get(@key, nil),
           true <- :persistent_term.erase(@key),
           do: fun.()

      {:ok, value}
    end

    @impl true
    def finish(nil), do: :ok
  end

  defmodule UnpreparableResolver do
    @moduledoc "A resolver whose chunk can't be readied, as a corrupt companion ZIP."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:error, :test_resolver_unprepared}

    @impl true
    def resolve(_args, _state, _context), do: {:error, :never}

    @impl true
    def finish(_state), do: :ok
  end

  # ── Test-only Storage adapter ─────────────────────────────────────────

  defmodule ErrorStorage do
    @moduledoc false
    @behaviour AshBulkDurable.Core.Storage

    @impl true
    def get_object(_key), do: {:error, :test_storage_offline}

    @impl true
    def delete_object(_key), do: :ok

    @impl true
    def list_objects(_prefix), do: {:ok, []}
  end

  # ── Setup helpers ─────────────────────────────────────────────────────

  defp messages(stored), do: Enum.map_join(stored, "; ", & &1.message)

  defp create_bulk_action!(rows, opts) do
    attrs = %{
      user_id: opts[:user_id],
      resource_name: @region_resource_name,
      action_name: :create,
      action_type: :create,
      staged_files: opts[:staged_files] || %{},
      total_rows: length(rows),
      mode: Keyword.get(opts, :mode, :per_row),
      chunk_size: Keyword.fetch!(opts, :chunk_size),
      rows: rows
    }

    Ash.create!(BulkAction, attrs, action: :create, authorize?: false)
  end

  defp regions_named(name, user) do
    Region |> Ash.Query.filter(name == ^name) |> Ash.read!(actor: user)
  end

  # `code`, `name`, and `native_name` are all global unique identities on `Region`.
  # `name`/`native_name` stay stable ("Region #{i}"/"Region AR #{i}") because the
  # poison resolvers key off them; that's safe only while this suite is
  # `async: false` (sync modules never run concurrently). `code` is suffixed
  # per bulk action so repeat runs within this module don't collide at the index.
  # With a `resolver`, each row's `native_name` is a reference to it.
  defp region_rows(n, suffix, resolver \\ nil) do
    Enum.map(1..n, fn i ->
      %{
        input: %{
          name: "Region #{i}",
          native_name: native_name("Region AR #{i}", resolver),
          code: "B#{i}-#{suffix}"
        }
      }
    end)
  end

  defp native_name(value, nil), do: value
  defp native_name(value, resolver), do: {:resolve, resolver, value}

  # The regions a bulk action created, by the suffix its codes carry — the table
  # also holds the region every test is set up with.
  defp regions_from(suffix, user) do
    Region
    |> Ash.Query.filter(contains(code, ^"-#{suffix}"))
    |> Ash.read!(actor: user, authorize?: false)
  end

  defp list_rows(bulk_action_id) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp reload(%BulkAction{id: id}), do: Ash.get!(BulkAction, id, authorize?: false)

  defp put_poison(value) do
    Application.put_env(:ash_bulk_durable, :test_poison, value)
    on_exit(fn -> Application.delete_env(:ash_bulk_durable, :test_poison) end)
  end

  # ── Tests ─────────────────────────────────────────────────────────────

  describe "happy path" do
    test "5 rows, chunk_size 2 → all succeeded, bulk action :completed, rows_done == 5",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(5, suffix), user_id: user.id, chunk_size: 2)

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed
      assert fresh.rows_done == 5
      assert %DateTime{} = fresh.started_at
      assert %DateTime{} = fresh.finished_at

      rows = list_rows(bulk_action.id)
      assert length(rows) == 5
      assert Enum.all?(rows, &(&1.status == :succeeded))
      assert Enum.all?(rows, &is_binary(&1.record_id))

      regions_count =
        Region
        |> Ash.Query.filter(code in ^Enum.map(1..5, &"B#{&1}-#{suffix}"))
        |> Ash.read!(actor: user, authorize?: false)
        |> length()

      assert regions_count == 5
    end
  end

  describe "best-effort recovery" do
    test "poison row 3 → row 3 :failed, rest :succeeded, bulk action :completed_with_errors, rows_done == 4",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      # Pre-create a Region matching row 3's code so its create violates the
      # `:code` identity and the chunk rolls back; row-by-row recovery
      # then succeeds rows 1, 2, 4, 5 and marks row 3 :failed.
      Ash.create!(
        Region,
        %{code: "B3-#{suffix}", name: "Existing 3", native_name: "Existing AR 3"},
        actor: user,
        authorize?: false
      )

      bulk_action =
        create_bulk_action!(region_rows(5, suffix), user_id: user.id, chunk_size: 2)

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == 4

      rows = list_rows(bulk_action.id)
      [r1, r2, r3, r4, r5] = rows
      assert r1.status == :succeeded
      assert r2.status == :succeeded
      assert r3.status == :failed
      assert r4.status == :succeeded
      assert r5.status == :succeeded

      # The :code clash is a DB-constraint failure → bulk_update returns the
      # errored changeset. It must serialize to a clean message, not a dump.
      assert messages(r3.error) =~ "code"
      refute messages(r3.error) =~ "Ash.Changeset"
    end

    test "two poisoned rows in one chunk → both :failed, the rest :succeeded, bulk action :completed_with_errors",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      # Pre-create Regions matching rows 2 and 3 so both clash on the `:code`
      # identity. With chunk_size 3 they land in the *same* chunk, so the
      # atomic batch rolls back and row-by-row recovery must mark BOTH bad
      # rows :failed while still committing the chunk's good row (B1) and all
      # of chunk 2 (B4–B6). Today's tests only ever poison one row per chunk.
      for code <- ["B2-#{suffix}", "B3-#{suffix}"] do
        Ash.create!(
          Region,
          %{code: code, name: "Existing #{code}", native_name: "Existing AR #{code}"},
          actor: user,
          authorize?: false
        )
      end

      bulk_action =
        create_bulk_action!(region_rows(6, suffix), user_id: user.id, chunk_size: 3)

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == 4

      [r1, r2, r3, r4, r5, r6] = list_rows(bulk_action.id)
      assert r1.status == :succeeded
      assert r2.status == :failed
      assert r3.status == :failed
      assert r4.status == :succeeded
      assert r5.status == :succeeded
      assert r6.status == :succeeded

      # Each poisoned row keeps its own clean per-row error — recovery neither
      # smears one failure across both nor leaks an inspect dump.
      for r <- [r2, r3] do
        assert messages(r.error) =~ "code"
        refute messages(r.error) =~ "Ash.Changeset"
      end
    end
  end

  describe "a raise while writing a row during recovery" do
    # The chunk returned an error, so this raise arrives in recovery: the
    # bad row lands :failed and the rest of the chunk commits normally.
    test "best-effort: a raising row lands :failed, the rest :succeeded",
         %{super_user: user} do
      put_poison("Region AR 3")

      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(5, suffix, RaiseOnRecoveryResolver),
          user_id: user.id,
          chunk_size: 2
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == 4

      [r1, r2, r3, r4, r5] = list_rows(bulk_action.id)
      assert r1.status == :succeeded
      assert r2.status == :succeeded
      assert r3.status == :failed
      assert r4.status == :succeeded
      assert r5.status == :succeeded

      assert is_binary(messages(r3.error)) and messages(r3.error) != ""
    end
  end

  describe "a row that raises on the chunk's first attempt" do
    setup do
      put_poison("Region AR 2")
      on_exit(fn -> Application.delete_env(:ash_bulk_durable, :test_raise_in) end)
      :ok
    end

    for {phase, message} <- [write: "test_write_raise", resolve: "test_resolve_raise"] do
      test "per row, raising at #{phase}: fails alone, logged, the rest run", %{super_user: user} do
        Application.put_env(:ash_bulk_durable, :test_raise_in, unquote(phase))
        suffix = System.unique_integer([:positive])

        bulk_action =
          create_bulk_action!(region_rows(5, suffix, RaisingResolver),
            user_id: user.id,
            chunk_size: 2
          )

        log =
          capture_log(fn ->
            assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
          end)

        assert log =~ "bulk action #{bulk_action.id} row 1 raised"
        assert log =~ unquote(message)

        fresh = reload(bulk_action)
        assert fresh.status == :completed_with_errors
        assert fresh.rows_done == 4

        [r1, r2, r3, r4, r5] = list_rows(bulk_action.id)
        assert Enum.map([r1, r3, r4, r5], & &1.status) == List.duplicate(:succeeded, 4)
        assert r2.status == :failed
        assert messages(r2.error) =~ unquote(message)

        assert length(regions_from(suffix, user)) == 4
      end
    end

    for {phase, reason} <- [
          write: "atomic_chunk_rolled_back",
          resolve: "atomic_phase1_failed"
        ] do
      test "all or nothing, raising at #{phase}: fails naming the row, nothing written", %{
        super_user: user
      } do
        Application.put_env(:ash_bulk_durable, :test_raise_in, unquote(phase))
        suffix = System.unique_integer([:positive])

        bulk_action =
          create_bulk_action!(region_rows(3, suffix, RaisingResolver),
            user_id: user.id,
            chunk_size: 3,
            mode: :all_or_nothing
          )

        assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

        fresh = reload(bulk_action)
        assert fresh.status == :failed
        assert fresh.result["reason"] == unquote(reason)
        assert fresh.result["row_index"] == 1
        assert fresh.rows_done == 0
        assert regions_from(suffix, user) == []
      end
    end
  end

  describe "pre-flight validation failure (returns {:error}, doesn't raise)" do
    # A row missing a required field makes Ash.create return {:error} *without*
    # raising (unlike a DB constraint). This used to MatchError-crash the chunk;
    # it must now land the row :failed with a clean error.
    test "best-effort: the invalid row :failed (clean error), the rest :succeeded",
         %{super_user: user} do
      n = System.unique_integer([:positive])

      rows = [
        %{input: %{name: "Valfix A #{n}", native_name: "AR A", code: "VA#{n}"}},
        %{input: %{name: "Valfix B #{n}", code: "VB#{n}"}},
        %{input: %{name: "Valfix C #{n}", native_name: "AR C", code: "VC#{n}"}}
      ]

      bulk_action = create_bulk_action!(rows, user_id: user.id, chunk_size: 2)
      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == 2

      [r1, r2, r3] = list_rows(bulk_action.id)
      assert r1.status == :succeeded
      assert r2.status == :failed
      assert r3.status == :succeeded

      assert messages(r2.error) =~ "native_name"
      refute messages(r2.error) =~ "(ash"
    end

    test "atomic: the whole bulk action :failed and no row applied (no crash)",
         %{super_user: user} do
      n = System.unique_integer([:positive])

      rows = [
        %{input: %{name: "Atomicfix A #{n}", native_name: "AR A", code: "AA#{n}"}},
        %{input: %{name: "Atomicfix B #{n}", code: "AB#{n}"}}
      ]

      bulk_action =
        create_bulk_action!(rows, user_id: user.id, chunk_size: 2, mode: :all_or_nothing)

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.result["reason"] == "atomic_chunk_rolled_back"
      # Holding no reference, every row was stored :resolved; the atomic
      # phase-2 rollback leaves them :resolved (not applied).
      assert Enum.all?(list_rows(bulk_action.id), &(&1.status == :resolved))
    end
  end

  describe "atomic-mode rollback" do
    test "row 3 poisoned in an all-or-nothing bulk action → no row applied, bulk action :failed, rows_done == 0",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      Ash.create!(
        Region,
        %{code: "B3-#{suffix}", name: "Existing 3", native_name: "Existing AR 3"},
        actor: user,
        authorize?: false
      )

      bulk_action =
        create_bulk_action!(region_rows(5, suffix),
          user_id: user.id,
          chunk_size: 5,
          mode: :all_or_nothing
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.rows_done == 0
      assert fresh.result["reason"] == "atomic_chunk_rolled_back"

      # The result captures the root cause: the poisoned row (B3, index 2)
      # and a humanized message — not an inspect dump.
      assert fresh.result["row_index"] == 2
      assert messages(fresh.error) =~ "has already been taken"
      refute messages(fresh.error) =~ "%Ash."

      rows = list_rows(bulk_action.id)
      # Holding no reference, every row was stored :resolved; the atomic
      # phase-2 rollback leaves them :resolved, having created no Regions.
      assert Enum.all?(rows, &(&1.status == :resolved))
      assert regions_from(suffix, user) |> length() == 1
    end
  end

  describe "phase 1 failure (best-effort)" do
    test "row 2's reference can't be resolved → row 2 :failed, rest :succeeded, bulk action :completed_with_errors",
         %{super_user: user} do
      put_poison("Region AR 2")

      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(5, suffix, PoisonResolver),
          user_id: user.id,
          chunk_size: 2
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == 4

      rows = list_rows(bulk_action.id)
      [r1, r2, r3, r4, r5] = rows
      assert r1.status == :succeeded
      assert r2.status == :failed
      assert r3.status == :succeeded
      assert r4.status == :succeeded
      assert r5.status == :succeeded
    end

    test "atomic-mode phase 1 failure halts before any chunk runs", %{super_user: user} do
      put_poison("Region AR 2")

      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(5, suffix, PoisonResolver),
          user_id: user.id,
          chunk_size: 5,
          mode: :all_or_nothing
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.rows_done == 0
      assert fresh.result["reason"] == "atomic_phase1_failed"

      # The result names the row whose resolve failed ("Region AR 2", index 1)
      # with a humanized message.
      assert fresh.result["row_index"] == 1
      assert is_binary(messages(fresh.error)) and messages(fresh.error) != ""

      assert regions_from(suffix, user) == []
    end
  end

  describe "crash-resume" do
    test "no-ops when the bulk action is already terminal (post-mark_finished crash window)",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(2, suffix),
          user_id: user.id,
          chunk_size: 2,
          mode: :all_or_nothing
        )

      # Simulate the first attempt having reached mark_finished but the
      # BEAM dying before Oban acked. The next attempt picks up a bulk action in
      # `:completed` state.
      Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)

      finished = reload(bulk_action)
      finished_at = finished.finished_at

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      reread = reload(bulk_action)
      assert reread.status == :completed
      # finished_at is not re-stamped — confirms mark_finished did NOT re-fire.
      assert reread.finished_at == finished_at
      # No Region rows created — the worker did not re-drive the chunks.
      assert regions_from(suffix, user) == []
    end

    test "pre-seeded :succeeded rows are skipped on the next attempt", %{super_user: user} do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(5, suffix), user_id: user.id, chunk_size: 2)

      # Simulate a crash after rows 1..3 committed in a previous attempt.
      list_rows(bulk_action.id)
      |> Enum.take(3)
      |> Enum.with_index()
      |> Enum.each(fn {row, idx} ->
        Ash.update!(row, %{record_id: "stub-#{idx}"},
          action: :mark_succeeded,
          authorize?: false
        )
      end)

      bulk_action
      |> Ash.Changeset.for_update(:bump_rows_done, %{n: 3}, authorize?: false)
      |> Ash.update!(authorize?: false)

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed
      assert fresh.rows_done == 5

      [r1, r2, r3, r4, r5] = list_rows(bulk_action.id)
      assert r1.record_id == "stub-0"
      assert r2.record_id == "stub-1"
      assert r3.record_id == "stub-2"
      assert is_binary(r4.record_id) and not String.starts_with?(r4.record_id, "stub-")
      assert is_binary(r5.record_id) and not String.starts_with?(r5.record_id, "stub-")

      # Only rows 4..5 created Region records, so the count is 2.
      assert regions_from(suffix, user) |> length() == 2
    end
  end

  describe "a resolver that finds nothing" do
    test "fails its row alone, the bulk action going on", %{super_user: user} do
      suffix = System.unique_integer([:positive])
      [unmatched | others] = region_rows(3, suffix)

      bulk_action =
        create_bulk_action!(
          [put_in(unmatched.input.native_name, native_name("x", NoMatchResolver)) | others],
          user_id: user.id,
          chunk_size: 2
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      assert reload(bulk_action).status == :completed_with_errors
      assert length(regions_from(suffix, user)) == 2

      assert [%{status: :failed, error: error}, %{status: :succeeded}, %{status: :succeeded}] =
               list_rows(bulk_action.id) |> Enum.sort_by(& &1.row_index)

      assert messages(error) =~ "no match"
    end
  end

  describe "a resolver that can't be prepared" do
    test "a resolver that can't be readied → bulk action :failed, no row written", %{
      super_user: user
    } do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(3, suffix, UnpreparableResolver),
          user_id: user.id,
          chunk_size: 2
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.result["reason"] == "resolver_prepare_error"
      assert fresh.result["term"] =~ "test_resolver_unprepared"

      assert regions_from(suffix, user) == []
      assert list_rows(bulk_action.id) |> Enum.all?(&(&1.status == :pending))
    end
  end

  describe "staged-file download error" do
    test "all or nothing: storage adapter returns :error → bulk action :failed, no Oban raise", %{
      super_user: user
    } do
      put_storage(ErrorStorage)

      suffix = System.unique_integer([:positive])

      rows =
        3
        |> region_rows(suffix)
        |> Enum.map(&put_in(&1, [:input, :name], {:resolve, AshBulkDurable.EchoResolver, "Name"}))

      bulk_action =
        create_bulk_action!(rows,
          user_id: user.id,
          mode: :all_or_nothing,
          chunk_size: 3,
          staged_files: %{"logo" => "bulk-staging/#{user.id}/abc/companions/logo.zip"}
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.result["reason"] == "staged_file_download_error"

      assert regions_from(suffix, user) == []
    end

    test "a row whose tenant a resolver has yet to resolve needs the staged files", %{
      super_user: user
    } do
      put_storage(ErrorStorage)

      rows =
        1
        |> region_rows(System.unique_integer([:positive]))
        |> Enum.map(
          &Map.put(&1, :target, %{tenant: {:resolve, AshBulkDurable.EchoResolver, "t"}})
        )

      bulk_action =
        create_bulk_action!(rows,
          user_id: user.id,
          chunk_size: 2,
          staged_files: %{"tenants" => "bulk-staging/#{user.id}/abc/companions/tenants.csv"}
        )

      capture_log(fn ->
        assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
      end)

      assert %{status: :completed_with_errors} = reload(bulk_action)

      assert [%{status: :failed, error: [%{error: %StagedFileError{}}]}] =
               list_rows(bulk_action.id)
    end

    test "per row: only a row a resolver has yet to reach fails, a lookup left to run doesn't",
         %{super_user: user} do
      put_storage(ErrorStorage)

      found_code = "G#{System.unique_integer([:positive])}"

      found =
        Ash.create!(
          Region,
          %{code: found_code, name: "N #{found_code}", native_name: "ا #{found_code}"},
          actor: user
        )

      [needs_file, looks_up] =
        region_rows(2, System.unique_integer([:positive]))
        |> then(fn [first, second] ->
          [
            put_in(first, [:input, :name], {:resolve, AshBulkDurable.EchoResolver, "Name"}),
            put_in(second, [:input, :name], {:lookup, Region, :code, found_code})
          ]
        end)

      bulk_action =
        create_bulk_action!([needs_file, looks_up],
          user_id: user.id,
          chunk_size: 2,
          staged_files: %{"logo" => "bulk-staging/#{user.id}/abc/companions/logo.zip"}
        )

      capture_log(fn ->
        assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
      end)

      assert %{status: :completed_with_errors, rows_done: 1} = reload(bulk_action)

      assert [%{status: :failed, error: [%{error: %StagedFileError{}}]}, %{status: :succeeded}] =
               bulk_action.id |> list_rows() |> Enum.sort_by(& &1.row_index)

      assert [%{name: name}] = regions_named(found.id, user)
      assert name == found.id
    end

    test "rows with nothing left to resolve run without the staged files", %{super_user: user} do
      put_storage(ErrorStorage)

      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(3, suffix),
          user_id: user.id,
          chunk_size: 2,
          staged_files: %{"logo" => "bulk-staging/#{user.id}/abc/companions/logo.zip"}
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      assert reload(bulk_action).status == :completed
      assert length(regions_from(suffix, user)) == 3
    end
  end

  # The cleanup keys off the bulk action record `mark_finished/2` just returned
  # — re-reading the row here would open a window where a racing writer
  # could flip the purge decision (see the RescueStuckBulkActions TOCTOU). Both
  # purge branches must therefore reflect the terminal status the worker
  # itself wrote.
  describe "staged-file cleanup gates on the worker's terminal status" do
    setup do
      AshBulkDurable.StorageHelpers.put_config(:storage, AshBulkDurable.TestStorage)
      start_supervised!(AshBulkDurable.TestStorage)
      :ok
    end

    defp seed_staging(user_id) do
      key = "bulk-staging/#{user_id}/abc/companions/logo.zip"
      AshBulkDurable.TestStorage.put(key, "")
      key
    end

    test "deletes staging when the bulk action lands :completed", %{super_user: user} do
      key = seed_staging(user.id)

      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(3, suffix),
          user_id: user.id,
          chunk_size: 2,
          staged_files: %{"logo" => key}
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
      assert reload(bulk_action).status == :completed
      refute key in AshBulkDurable.TestStorage.keys()
    end

    test "preserves staging when the bulk action lands :completed_with_errors", %{
      super_user: user
    } do
      key = seed_staging(user.id)

      suffix = System.unique_integer([:positive])

      # Pre-create row 2's code so it fails the unique check and the bulk action
      # lands :completed_with_errors — the user may retry the failed
      # row, so its staged file must survive.
      Ash.create!(Region, %{code: "B2-#{suffix}", name: "X", native_name: "X"},
        actor: user,
        authorize?: false
      )

      bulk_action =
        create_bulk_action!(region_rows(3, suffix),
          user_id: user.id,
          chunk_size: 2,
          staged_files: %{"logo" => key}
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
      assert reload(bulk_action).status == :completed_with_errors
      assert key in AshBulkDurable.TestStorage.keys()
    end

    test "preserves staging when the bulk action lands :failed, which can be retried", %{
      super_user: user
    } do
      key = seed_staging(user.id)
      suffix = System.unique_integer([:positive])

      Ash.create!(Region, %{code: "B2-#{suffix}", name: "X#{suffix}", native_name: "Y#{suffix}"},
        actor: user,
        authorize?: false
      )

      bulk_action =
        create_bulk_action!(region_rows(3, suffix),
          user_id: user.id,
          chunk_size: 3,
          mode: :all_or_nothing,
          chunk_size: 2,
          staged_files: %{"logo" => key}
        )

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
      assert reload(bulk_action).status == :failed
      assert key in AshBulkDurable.TestStorage.keys()
    end
  end

  # A row its caller refused before storing it (a sheet's cell a handler
  # couldn't read) is stored :failed and never run.
  describe "a row stored refused" do
    defp refused(row) do
      Map.put(
        row,
        :error,
        Ash.Error.Changes.InvalidAttribute.exception(field: :native_name, message: "unreadable")
      )
    end

    test "per row: it stays :failed with its error, the rest :succeeded", %{super_user: user} do
      suffix = System.unique_integer([:positive])
      rows = region_rows(3, suffix) |> List.update_at(1, &refused/1)

      bulk_action = create_bulk_action!(rows, user_id: user.id, chunk_size: 2)
      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == 2

      [r1, r2, r3] = list_rows(bulk_action.id)
      assert {r1.status, r2.status, r3.status} == {:succeeded, :failed, :succeeded}
      assert messages(r2.error) =~ "unreadable"
      assert regions_from(suffix, user) |> length() == 2
    end

    test "all or nothing: the bulk action fails naming it, before anything is written",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      rows =
        region_rows(3, suffix, AshBulkDurable.EchoResolver) |> List.update_at(2, &refused/1)

      bulk_action =
        create_bulk_action!(rows, user_id: user.id, chunk_size: 3, mode: :all_or_nothing)

      assert :ok = perform_job(Worker, %{"bulk_action_id" => bulk_action.id})

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.result["reason"] == "atomic_phase1_failed"
      assert fresh.result["row_index"] == 2
      assert messages(fresh.error) =~ "unreadable"

      # Nothing was resolved, let alone written.
      assert Enum.map(list_rows(bulk_action.id), & &1.status) == [:pending, :pending, :failed]
      assert regions_from(suffix, user) == []
    end
  end

  # Another run of the same bulk action writes a row between this run reading
  # it and flipping it. The flip is refused, the transaction holding it rolls
  # back, and this run stops without a verdict of its own.
  describe "a row moved on under another run" do
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

    defp move_in_resolve(fun) do
      on_exit(&MovingResolver.clear/0)
      MovingResolver.hook(fun)
    end

    # The bulk action as this run's `mark_running` left it: no verdict.
    defp assert_no_verdict(bulk_action) do
      fresh = reload(bulk_action)
      assert fresh.status == :running
      assert fresh.result == nil
      assert fresh.finished_at == nil
      assert fresh.rows_done == 0
    end

    defp perform_as_current(bulk_action) do
      Worker
      |> build_job(%{"bulk_action_id" => bulk_action.id})
      |> Map.put(:id, bulk_action.oban_job_id)
      |> perform_job()
    end

    test "phase 1, per row: the current job's resolve is refused and it retries",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(1, suffix, MovingResolver),
          user_id: user.id,
          chunk_size: 1
        )

      [row] = list_rows(bulk_action.id)

      move_in_resolve(fn ->
        Ash.Seed.update!(row, %{status: :resolved, resolved_data: %{"native_name" => "other"}})
      end)

      log =
        capture_log(fn -> assert {:error, :row_moved_on} = perform_as_current(bulk_action) end)

      assert log =~ "a stale run wrote a row first"

      assert [%{status: :resolved, resolved_data: %{"native_name" => "other"}}] =
               list_rows(bulk_action.id)

      assert_no_verdict(bulk_action)
      assert regions_from(suffix, user) == []
    end

    test "phase 1, all or nothing: a superseded job's resolve is refused and it cancels",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(2, suffix, MovingResolver),
          user_id: user.id,
          chunk_size: 2,
          mode: :all_or_nothing
        )

      [row | _] = list_rows(bulk_action.id)

      move_in_resolve(fn ->
        Ash.Seed.update!(row, %{status: :failed, error: "other run"})
      end)

      log =
        capture_log(fn ->
          assert {:cancel, :superseded} =
                   perform_job(Worker, %{"bulk_action_id" => bulk_action.id})
        end)

      assert log =~ "is superseded"

      [r1, r2] = list_rows(bulk_action.id)
      assert r1.status == :failed
      assert [%{message: "other run"}] = r1.error
      assert r2.status in [:pending, :resolved]
      assert_no_verdict(bulk_action)
      assert regions_from(suffix, user) == []
    end

    test "phase 2, per row: the chunk rolls back with no recovery, and a job of a finished bulk action cancels",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(2, suffix), user_id: user.id, chunk_size: 2)

      [r1, r2] = list_rows(bulk_action.id)

      # The other run applied row 2 and finished the bulk action.
      at_first_chunk(bulk_action, fn ->
        Ash.Seed.update!(r2, %{status: :succeeded, record_id: "other"})
        Ash.Seed.update!(reload(bulk_action), %{status: :completed})
      end)

      log =
        capture_log(fn -> assert {:cancel, :superseded} = perform_as_current(bulk_action) end)

      assert log =~ "is superseded"

      # Row 1's target write and flip shared the refused flip's transaction.
      assert regions_from(suffix, user) == []

      assert [%{id: id1, status: :resolved}, %{status: :succeeded, record_id: "other"}] =
               list_rows(bulk_action.id)

      assert id1 == r1.id

      fresh = reload(bulk_action)
      assert fresh.status == :completed
      assert fresh.result == nil
      assert fresh.rows_done == 0
    end

    test "phase 2, all or nothing: the transaction rolls back, no rollback verdict, and the current job retries",
         %{super_user: user} do
      suffix = System.unique_integer([:positive])

      bulk_action =
        create_bulk_action!(region_rows(2, suffix),
          user_id: user.id,
          chunk_size: 2,
          mode: :all_or_nothing
        )

      [_r1, r2] = list_rows(bulk_action.id)

      at_first_chunk(bulk_action, fn ->
        Ash.Seed.update!(r2, %{status: :succeeded, record_id: "other"})
      end)

      log =
        capture_log(fn -> assert {:error, :row_moved_on} = perform_as_current(bulk_action) end)

      assert log =~ "a stale run wrote a row first"

      assert regions_from(suffix, user) == []

      assert [%{status: :resolved}, %{status: :succeeded, record_id: "other"}] =
               list_rows(bulk_action.id)

      assert_no_verdict(bulk_action)
    end
  end
end
