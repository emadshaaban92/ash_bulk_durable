defmodule AshBulkDurable.Core.ReadRepoTest do
  @moduledoc """
  Reads made under the bulk action lock go to the lock's connection, the
  mutate repo, even when the bulk action resources send their reads to
  another repo, as a host with a read replica does. A replica sees neither
  the lock nor the transaction's own writes. Runs outside the sandbox, as the
  other lock tests do, and deletes what it wrote.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  defmodule LosingResolver do
    @moduledoc "Resolves a value to itself, and finds every value it kept lost."
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(value, nil, _context), do: {:ok, value}

    @impl true
    def finish(nil), do: :ok

    @impl true
    def lost(values, _context), do: values
  end

  alias AshBulkDurable.Core.Worker
  alias AshBulkDurable.Test.{BulkAction, ReadRepo, Region, Repo, Row, Scope, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ReadRepo, sandbox: false)
    Application.put_env(:ash_bulk_durable, :test_read_repo, ReadRepo)
    tag = "rrepo#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:ash_bulk_durable, :test_read_repo)
      cleanup(tag)
    end)

    user = create_user!(tag)
    %{user: user, scope: Scope.new(actor: user), tag: tag}
  end

  test "every read inside a locked transaction goes to the mutate repo", ctx do
    replica = watch_replica()
    bulk_action = submit!(ctx)
    [r1, _r2, _r3, r4] = rows(bulk_action)

    # Row 1 is a suspect, run alone; row 2's code is taken, so its chunk is
    # recovered row by row; row 4 kept a resolution its resolver has lost.
    set_row!(r1, "attempts = 1")
    taken = taken!(ctx, 2)
    set_row!(r4, ~s(status = 'resolved', resolved_data = '{"native_name": "#{ctx.tag} A4"}'))

    assert :ok = Worker.run_now(bulk_action.id)
    assert statuses(bulk_action) == [:succeeded, :failed, :succeeded, :succeeded]
    assert %{status: :completed_with_errors} = reload(bulk_action)

    # A retry reads the rows it reopens under the lock too.
    Ash.destroy!(taken, authorize?: false)
    assert {:ok, _retried} = AshBulkDurable.retry(reload(bulk_action), scope: ctx.scope)
    assert :ok = Worker.run_now(bulk_action.id)
    assert %{status: :completed, rows_done: 4} = reload(bulk_action)

    %{reads: reads, under_lock: under_lock} = replica.()
    # The replica served the reads made outside the lock.
    assert reads > 0
    assert under_lock == []
  end

  # Counts the stand-in replica's queries, and keeps those made while the
  # calling process was inside a transaction of the mutate repo.
  defp watch_replica do
    {:ok, agent} = Agent.start_link(fn -> %{reads: 0, under_lock: []} end)
    handler = "replica-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :test, :read_repo, :query],
      fn _event, _measurements, metadata, _config ->
        under_lock = if Repo.in_transaction?(), do: [metadata.query], else: []

        Agent.update(agent, fn state ->
          %{state | reads: state.reads + 1, under_lock: under_lock ++ state.under_lock}
        end)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fn -> Agent.get(agent, & &1) end
  end

  defp submit!(ctx) do
    plain =
      Enum.map(1..3, fn i ->
        %{
          input: %{
            code: "#{ctx.tag}-#{i}",
            name: "#{ctx.tag} N#{i}",
            native_name: "#{ctx.tag} A#{i}"
          }
        }
      end)

    resolving = %{
      input: %{
        code: "#{ctx.tag}-4",
        name: "#{ctx.tag} N4",
        native_name: {:resolve, LosingResolver, "#{ctx.tag} A4"}
      }
    }

    Ash.create!(
      BulkAction,
      %{
        user_id: ctx.user.id,
        resource_name: inspect(Region),
        action_name: :create,
        action_type: :create,
        total_rows: 4,
        mode: :per_row,
        chunk_size: 2,
        rows: plain ++ [resolving]
      },
      action: :create,
      authorize?: false
    )
  end

  defp taken!(ctx, i) do
    Ash.create!(
      Region,
      %{code: "#{ctx.tag}-#{i}", name: "#{ctx.tag} X#{i}", native_name: "X#{i}"},
      authorize?: false
    )
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp statuses(bulk_action), do: Enum.map(rows(bulk_action), & &1.status)

  defp reload(bulk_action), do: Ash.get!(BulkAction, bulk_action.id, authorize?: false)

  defp set_row!(row, set) do
    Repo.query!("UPDATE bulk_action_rows SET #{set} WHERE id = $1", [Ecto.UUID.dump!(row.id)])
  end

  defp create_user!(tag) do
    Ash.create!(User, %{name: "Replica", email: "#{tag}@example.test"},
      action: :create_super,
      authorize?: false
    )
  end

  defp cleanup(tag) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    users = "SELECT id FROM users WHERE email LIKE '%' || $1"
    email = "#{tag}@example.test"

    Repo.query!("DELETE FROM bulk_actions WHERE user_id IN (#{users})", [email])
    Repo.query!("DELETE FROM regions WHERE code LIKE $1 || '-%'", [tag])
    Repo.query!("DELETE FROM users WHERE id IN (#{users})", [email])
  end
end
