defmodule AshBulkDurable.Core.BulkActionLockTest do
  @moduledoc """
  `BulkActionLock`, `Retry` taking it before any row, `abandon/2` taking
  it before its write, and the staging sweep taking it before its deletes.
  A lock held by another transaction needs a second real connection, so this
  test runs outside the sandbox and deletes what it wrote.
  """
  use ExUnit.Case, async: false

  import Ash.Expr, only: [expr: 1]

  require Ash.Expr
  require Ash.Query

  alias AshBulkDurable.Core.{BulkActionLock, PurgeStaleStaging}
  alias AshBulkDurable.Test.{BulkAction, Region, Repo, Row, Scope, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    tag = "lock-#{System.unique_integer([:positive])}"

    user = create_user!(tag)
    on_exit(fn -> cleanup(tag) end)
    %{user: user, scope: Scope.new(actor: user), tag: tag}
  end

  # A bulk action finished with every row failed, as a run leaves it.
  defp finished_with_errors!(ctx) do
    inputs = Enum.map(1..2, &%{code: "#{ctx.tag}-#{&1}", name: "R#{&1}", native_name: "R#{&1}"})
    {:ok, bulk_action} = AshBulkDurable.bulk_create(inputs, Region, :create, scope: ctx.scope)
    id = Ecto.UUID.dump!(bulk_action.id)

    Repo.query!("UPDATE bulk_actions SET status = 'completed_with_errors' WHERE id = $1", [id])
    Repo.query!("UPDATE bulk_action_rows SET status = 'failed' WHERE bulk_action_id = $1", [id])

    Ash.get!(BulkAction, bulk_action.id, authorize?: false)
  end

  defp failed!(bulk_action) do
    Repo.query!("UPDATE bulk_actions SET status = 'failed' WHERE id = $1", [
      Ecto.UUID.dump!(bulk_action.id)
    ])

    Ash.get!(BulkAction, bulk_action.id, authorize?: false)
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp in_transaction(fun) do
    {:ok, result} = Repo.transaction(fun)
    result
  end

  describe "lock/2" do
    test "returns the bulk action while its status matches", ctx do
      bulk_action = finished_with_errors!(ctx)

      assert {:ok, %{id: id}} =
               in_transaction(fn ->
                 BulkActionLock.lock(bulk_action.id, [:completed_with_errors])
               end)

      assert id == bulk_action.id
    end

    test "returns :none when its status doesn't match", ctx do
      bulk_action = finished_with_errors!(ctx)

      assert :none =
               in_transaction(fn -> BulkActionLock.lock(bulk_action.id, [:running, :queued]) end)
    end

    test "returns :none when its :filter doesn't match", ctx do
      bulk_action = finished_with_errors!(ctx)
      other = Ecto.UUID.generate()

      assert :none =
               in_transaction(fn ->
                 BulkActionLock.lock(bulk_action.id, [:completed_with_errors],
                   filter: expr(user_id == ^other)
                 )
               end)
    end

    test "returns :none while another connection holds it", ctx do
      bulk_action = finished_with_errors!(ctx)
      locker = lock_elsewhere(bulk_action.id)

      assert :none =
               in_transaction(fn ->
                 BulkActionLock.lock(bulk_action.id, [:completed_with_errors])
               end)

      release(locker)
    end

    test "raises outside a transaction", ctx do
      bulk_action = finished_with_errors!(ctx)

      assert_raise ArgumentError, ~r/inside a transaction/, fn ->
        BulkActionLock.lock(bulk_action.id, [:completed_with_errors])
      end
    end
  end

  describe "retry while another transaction holds the bulk action" do
    test "retry/2 and retry_row/2 are refused at once, nothing written", ctx do
      bulk_action = finished_with_errors!(ctx)
      [row | _rows] = rows(bulk_action)
      locker = lock_elsewhere(bulk_action.id)

      for retry <- [
            fn -> AshBulkDurable.retry(bulk_action, scope: ctx.scope) end,
            fn -> AshBulkDurable.retry_row(row, scope: ctx.scope) end
          ] do
        {micros, result} = :timer.tc(retry)

        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} = result
        assert micros < 500_000
      end

      release(locker)

      assert Enum.map(rows(bulk_action), & &1.status) == [:failed, :failed]
      assert Ash.get!(BulkAction, bulk_action.id, authorize?: false) == bulk_action
    end
  end

  describe "retry of a failed bulk action while a submit takes its owner's slot" do
    # A failed one has given up the owner's one unresolved slot, so its retry
    # checks the slot under the lock. A submit can still land after that
    # check: the one-unresolved index refuses the retry's update instead.
    test "is refused with the submitted one's id, nothing written", ctx do
      bulk_action = failed!(finished_with_errors!(ctx))
      rows = rows(bulk_action)
      test_pid = self()

      retry =
        spawn_link(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          receive do
            :start -> :ok
          end

          send(test_pid, {:retried, AshBulkDurable.retry(bulk_action, scope: ctx.scope)})
        end)

      # The retry stops at its first row write, past the slot check.
      handler = "submit-during-retry-#{ctx.tag}"

      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :test, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == retry and source == "bulk_action_rows" and
               String.starts_with?(query, "UPDATE") do
            :telemetry.detach(handler)
            send(test_pid, :retrying)

            receive do
              :go -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      send(retry, :start)
      assert_receive :retrying, 2_000

      input = %{code: "#{ctx.tag}-new", name: "New", native_name: "New"}
      {:ok, submitted} = AshBulkDurable.bulk_create([input], Region, :create, scope: ctx.scope)
      submitted_id = submitted.id

      send(retry, :go)
      assert_receive {:retried, {:error, %{unresolved: ^submitted_id}}}, 2_000

      assert Ash.get!(BulkAction, bulk_action.id, authorize?: false) == bulk_action
      assert rows(bulk_action) == rows
    end
  end

  test "a caller who doesn't own it is refused before reading a row", ctx do
    bulk_action = finished_with_errors!(ctx)
    [row | _rows] = rows(bulk_action)
    stranger = Scope.new(actor: create_user!("stranger-#{ctx.tag}"))
    test_pid = self()
    handler = "lock-rows-read-#{ctx.tag}"

    # A read of a row's columns, not `retry_row`'s lookup of the bulk action
    # the caller's own row names.
    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :test, :repo, :query],
      fn _event, _measurements, %{source: source, query: query}, _config ->
        if self() == test_pid and source == "bulk_action_rows" and
             String.contains?(query, ~s("status")),
           do: send(test_pid, :rows_read)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             AshBulkDurable.retry(bulk_action, scope: stranger)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             AshBulkDurable.retry_row(row, scope: stranger)

    refute_received :rows_read
    :telemetry.detach(handler)

    assert Enum.map(rows(bulk_action), & &1.status) == [:failed, :failed]
    assert Enum.all?(rows(bulk_action), &unlocked?/1)
    assert Ash.get!(BulkAction, bulk_action.id, authorize?: false) == bulk_action
  end

  describe "abandon/2" do
    setup do
      AshBulkDurable.StorageHelpers.put_config(:storage, AshBulkDurable.TestStorage)
      start_supervised!(AshBulkDurable.TestStorage)
      :ok
    end

    test "while a retry's transaction holds the bulk action, is refused at once, " <>
           "changing nothing",
         ctx do
      bulk_action = with_staged_file!(finished_with_errors!(ctx), ctx)
      test_pid = self()

      retry =
        spawn_link(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          send(test_pid, {:retried, AshBulkDurable.retry(bulk_action, scope: ctx.scope)})
        end)

      # The retry stops at its first row write, its lock held.
      handler = "abandon-during-retry-#{ctx.tag}"

      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :test, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == retry and source == "bulk_action_rows" and
               String.starts_with?(query, "UPDATE") do
            :telemetry.detach(handler)
            send(test_pid, :retrying)

            receive do
              :go -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert_receive :retrying, 2_000

      abandon =
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          AshBulkDurable.abandon(bulk_action, scope: ctx.scope)
        end)

      result = Task.yield(abandon, 500) || Task.shutdown(abandon, :brutal_kill)

      assert {:ok, {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}}} =
               result

      assert Ash.get!(BulkAction, bulk_action.id, authorize?: false) == bulk_action
      assert "bulk-staging/#{ctx.tag}/a.zip" in AshBulkDurable.TestStorage.keys()

      send(retry, :go)
      assert_receive {:retried, {:ok, %{status: :queued}}}, 2_000
      assert "bulk-staging/#{ctx.tag}/a.zip" in AshBulkDurable.TestStorage.keys()
    end

    test "by a caller who doesn't own it, is refused before any write", ctx do
      bulk_action = with_staged_file!(finished_with_errors!(ctx), ctx)
      stranger = Scope.new(actor: create_user!("stranger-#{ctx.tag}"))
      writes = count_bulk_action_writes()

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
               AshBulkDurable.abandon(bulk_action, scope: stranger)

      assert writes.() == 0
      assert Ash.get!(BulkAction, bulk_action.id, authorize?: false) == bulk_action
      assert "bulk-staging/#{ctx.tag}/a.zip" in AshBulkDurable.TestStorage.keys()

      # Its owner's abandon writes once, and deletes the file after it commits.
      assert {:ok, %{status: :cancelled}} = AshBulkDurable.abandon(bulk_action, scope: ctx.scope)
      assert writes.() == 1
      refute "bulk-staging/#{ctx.tag}/a.zip" in AshBulkDurable.TestStorage.keys()
    end
  end

  describe "the staging sweep" do
    setup do
      AshBulkDurable.StorageHelpers.put_config(:storage, AshBulkDurable.TestStorage)
      start_supervised!(AshBulkDurable.TestStorage)
      :ok
    end

    test "keeps the files of a long-failed bulk action while a retry's transaction " <>
           "holds it",
         ctx do
      bulk_action = failed_a_day_ago!(ctx)
      key = "bulk-staging/#{ctx.tag}/a.zip"
      test_pid = self()

      retry =
        spawn_link(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
          send(test_pid, {:retried, AshBulkDurable.retry(bulk_action, scope: ctx.scope)})
        end)

      # The retry stops at its first row write, its lock held.
      handler = "sweep-during-retry-#{ctx.tag}"

      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :test, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == retry and source == "bulk_action_rows" and
               String.starts_with?(query, "UPDATE") do
            :telemetry.detach(handler)
            send(test_pid, :retrying)

            receive do
              :go -> :ok
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      assert_receive :retrying, 2_000

      assert :ok = PurgeStaleStaging.sweep()
      assert key in AshBulkDurable.TestStorage.keys()

      send(retry, :go)
      assert_receive {:retried, {:ok, %{status: :queued}}}, 2_000
      assert key in AshBulkDurable.TestStorage.keys()
    end

    test "keeps the files of a long-failed bulk action retried after it read them", ctx do
      bulk_action = failed_a_day_ago!(ctx)
      key = "bulk-staging/#{ctx.tag}/a.zip"
      test_pid = self()
      handler = "retry-after-sweep-read-#{ctx.tag}"

      # The retry commits from a connection of its own once the sweep has
      # read which bulk actions hold its stale keys, before it locks them.
      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :test, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == test_pid and source == "bulk_actions" and
               String.starts_with?(query, "SELECT") and
               not String.contains?(query, "FOR NO KEY UPDATE") do
            :telemetry.detach(handler)

            retried =
              Task.async(fn ->
                :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
                AshBulkDurable.retry(bulk_action, scope: ctx.scope)
              end)
              |> Task.await()

            send(test_pid, {:retried, retried})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = PurgeStaleStaging.sweep()
      assert_received {:retried, {:ok, %{status: :queued}}}
      assert key in AshBulkDurable.TestStorage.keys()
    end

    test "keeps a file two long-failed bulk actions share once one is retried after it " <>
           "read them",
         ctx do
      retried = failed_a_day_ago!(ctx)
      _other = failed_a_day_ago!(ctx)
      key = "bulk-staging/#{ctx.tag}/a.zip"
      test_pid = self()
      handler = "retry-one-holder-#{ctx.tag}"

      # Both read as releasable; one is retried before the sweep locks them.
      :telemetry.attach(
        handler,
        [:ash_bulk_durable, :test, :repo, :query],
        fn _event, _measurements, %{source: source, query: query}, _config ->
          if self() == test_pid and source == "bulk_actions" and
               String.starts_with?(query, "SELECT") and
               not String.contains?(query, "FOR NO KEY UPDATE") do
            :telemetry.detach(handler)

            result =
              Task.async(fn ->
                :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
                AshBulkDurable.retry(retried, scope: ctx.scope)
              end)
              |> Task.await()

            send(test_pid, {:retried, result})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert :ok = PurgeStaleStaging.sweep()
      assert_received {:retried, {:ok, %{status: :queued}}}
      assert key in AshBulkDurable.TestStorage.keys()
    end

    test "deletes the files of a long-failed bulk action no one else holds", ctx do
      failed_a_day_ago!(ctx)

      assert :ok = PurgeStaleStaging.sweep()
      refute "bulk-staging/#{ctx.tag}/a.zip" in AshBulkDurable.TestStorage.keys()
    end
  end

  # A bulk action that failed over a day ago, its rows failed, and one file
  # staged for it over a day ago too: the sweep's to delete.
  defp failed_a_day_ago!(ctx) do
    bulk_action = with_staged_file!(finished_with_errors!(ctx), ctx)
    a_day_ago = DateTime.add(DateTime.utc_now(), -(24 * 60 * 60 + 60), :second)

    Repo.query!(
      "UPDATE bulk_actions SET status = 'failed', finished_at = $1 WHERE id = $2",
      [a_day_ago, Ecto.UUID.dump!(bulk_action.id)]
    )

    AshBulkDurable.TestStorage.put("bulk-staging/#{ctx.tag}/a.zip", "x", a_day_ago)
    Ash.get!(BulkAction, bulk_action.id, authorize?: false)
  end

  # One file staged for `bulk_action`, in the store and on the record.
  defp with_staged_file!(bulk_action, ctx) do
    key = "bulk-staging/#{ctx.tag}/a.zip"
    AshBulkDurable.TestStorage.put(key)

    Repo.query!("UPDATE bulk_actions SET staged_files = $1 WHERE id = $2", [
      %{"a.zip" => key},
      Ecto.UUID.dump!(bulk_action.id)
    ])

    Ash.get!(BulkAction, bulk_action.id, authorize?: false)
  end

  # The writes to `bulk_actions` the test process makes from now on.
  defp count_bulk_action_writes do
    test_pid = self()
    counter = :counters.new(1, [])
    handler = "bulk-action-writes-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :test, :repo, :query],
      fn _event, _measurements, %{source: source, query: query}, _config ->
        if self() == test_pid and source == "bulk_actions" and
             String.starts_with?(query, "UPDATE"),
           do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fn -> :counters.get(counter, 1) end
  end

  # Whether another connection can lock `row` without waiting.
  defp unlocked?(row) do
    Task.async(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

      {:ok, locked} =
        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM bulk_action_rows WHERE id = $1 FOR UPDATE SKIP LOCKED", [
            Ecto.UUID.dump!(row.id)
          ]).num_rows == 1
        end)

      locked
    end)
    |> Task.await()
  end

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

  defp create_user!(tag) do
    Ash.create!(User, %{name: "Lock", email: "#{tag}@example.test"},
      action: :create_super,
      authorize?: false
    )
  end

  # Every user the test made has an email ending in its tag.
  defp cleanup(tag) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    users = "SELECT id FROM users WHERE email LIKE '%' || $1"
    email = "#{tag}@example.test"

    Repo.query!("DELETE FROM bulk_actions WHERE user_id IN (#{users})", [email])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [email])
  end
end
