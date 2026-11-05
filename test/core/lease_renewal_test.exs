defmodule AshBulkDurable.Core.LeaseRenewalTest do
  @moduledoc """
  A long all-or-nothing run renews its lease while its one transaction is
  open. Two real connections are needed to show nothing in that transaction
  locks the bulk action's row, so this test runs outside the sandbox and
  deletes what it wrote.
  """
  use ExUnit.Case, async: false

  alias AshBulkDurable.Core.{Lease, Worker}
  alias AshBulkDurable.Test.{Asset, BulkAction, Repo, User}

  @rows 250

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    batch = "renewal-#{System.unique_integer([:positive])}"

    user =
      Ash.create!(User, %{name: "Renewal", email: "#{batch}@example.test"},
        action: :create_super,
        authorize?: false
      )

    on_exit(fn -> cleanup(batch, user) end)
    %{batch: batch, user: user}
  end

  test "a lease renews mid-transaction, without waiting for it", %{batch: batch, user: user} do
    bulk_action =
      Ash.create!(
        BulkAction,
        %{
          user_id: user.id,
          resource_name: inspect(Asset),
          action_name: :create,
          action_type: :create,
          total_rows: @rows,
          mode: :all_or_nothing,
          chunk_size: @rows,
          rows: Enum.map(1..@rows, &%{input: %{serial_number: "S#{&1}", batch_number: batch}})
        },
        action: :create,
        authorize?: false
      )

    {:ok, claimed} = Lease.claim_one(bulk_action.id)
    test_pid = self()
    handler = "lease-renewal-#{batch}"

    # Runs in the worker, inside the run's open transaction, after Ash's first
    # slice of rows: renew from another connection, as the renewer would.
    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :all_or_nothing, :progress],
      fn _event, %{rows_processed: processed}, %{bulk_action_id: id}, _config ->
        if id == claimed.id and processed < @rows do
          send(test_pid, {:renewed, processed, renew_elsewhere(claimed)})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Worker.run(claimed)

    assert_received {:renewed, processed, {:ok, before, renewed}}
    assert processed < @rows
    assert DateTime.compare(renewed, before) == :gt

    assert %{status: :completed, rows_done: @rows} =
             Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             )
  end

  test "a renewal stuck behind a lock stops the run by the lease's deadline", %{user: user} do
    previous = Application.get_env(:ash_bulk_durable, :lease_duration)
    Application.put_env(:ash_bulk_durable, :lease_duration, 600)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_bulk_durable, :lease_duration, previous),
        else: Application.delete_env(:ash_bulk_durable, :lease_duration)
    end)

    bulk_action =
      Ash.create!(
        BulkAction,
        %{
          user_id: user.id,
          resource_name: inspect(Asset),
          action_name: :create,
          action_type: :create,
          total_rows: 1,
          mode: :per_row,
          chunk_size: 1,
          rows: [%{input: %{serial_number: "S1", batch_number: "locked"}}]
        },
        action: :create,
        authorize?: false
      )

    {:ok, claimed} = Lease.claim_one(bulk_action.id)
    locker = lock_elsewhere(claimed.id)
    callers = [self()]

    # The deadline is 500 ms after the claim; the test's query timeout, a
    # minute, is what bounded it before.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        Lease.hold(claimed, fn -> Process.sleep(:infinity) end)
      end)

    started = System.monotonic_time(:millisecond)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:lease_lost, _id}}, 3_000
    assert System.monotonic_time(:millisecond) - started < 1_500

    send(locker, :release)
  end

  # Holds the bulk action's row lock from a connection of its own until told.
  defp lock_elsewhere(id) do
    test_pid = self()

    pid =
      spawn(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM bulk_actions WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(id)
          ])

          send(test_pid, :locked)

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end)
      end)

    assert_receive :locked, 2_000
    pid
  end

  # Its own connection, not the worker's; a lock held by the worker's
  # transaction would leave it waiting past the timeout.
  defp renew_elsewhere(claimed) do
    task =
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        Repo.query!("SET lock_timeout = '2s'")
        before = lease_until(claimed.id)
        result = Lease.renew(claimed.id, claimed.claim_token)
        {result, before, lease_until(claimed.id)}
      end)

    case Task.yield(task, :timer.seconds(5)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, before, renewed}} -> {:ok, before, renewed}
      other -> {:blocked, other}
    end
  end

  defp lease_until(id) do
    %{rows: [[lease_until]]} =
      Repo.query!("SELECT lease_until FROM bulk_actions WHERE id = $1", [Ecto.UUID.dump!(id)])

    DateTime.from_naive!(lease_until, "Etc/UTC")
  end

  defp cleanup(batch, user) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    Repo.query!("DELETE FROM assets WHERE batch_number = $1", [batch])
    Repo.query!("DELETE FROM bulk_actions WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])
    Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
  end
end
