defmodule AshBulkDurable.Core.ProgressTest do
  @moduledoc """
  The `"progress"` hints a run broadcasts while it commits nothing to its
  bulk action (`AshBulkDurable.Core.Progress`): an all-or-nothing write's
  slices, and phase 1's rows. Not async: some tests change
  `:progress_interval` or `:pubsub_module`, which every run reads.
  """
  use AshBulkDurable.DataCase, async: false

  alias AshBulkDurable.Core.Worker
  alias AshBulkDurable.Test.{BulkAction, PubSub}

  defmodule FailingResolver do
    @moduledoc false
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_value, nil, _context), do: {:error, :refused}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule RaisingPubSub do
    @moduledoc false
    def broadcast(_topic, _event, _payload), do: raise("pubsub down")
  end

  setup do
    previous = Application.get_all_env(:ash_bulk_durable)

    on_exit(fn ->
      for key <- [:progress_interval, :pubsub_module] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:ash_bulk_durable, key, value)
          :error -> Application.delete_env(:ash_bulk_durable, key)
        end
      end
    end)

    :ok
  end

  defp put_config(key, value), do: Application.put_env(:ash_bulk_durable, key, value)

  defp create_bulk_action!(rows, user_id, mode) do
    Ash.create!(
      BulkAction,
      %{
        user_id: user_id,
        resource_name: "AshBulkDurable.Test.Region",
        action_name: :create,
        action_type: :create,
        total_rows: length(rows),
        mode: mode,
        chunk_size: 50,
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  # Unique per test, since `Region`'s code and names are unique identities.
  defp region_rows(n, opts \\ []) do
    suffix = System.unique_integer([:positive])
    native = Keyword.get(opts, :native, &"AR #{&1}-#{&2}")

    Enum.map(1..n, fn i ->
      %{
        input: %{
          name: "Region #{i}-#{suffix}",
          native_name: native.(i, suffix),
          code: "P#{i}-#{suffix}"
        }
      }
    end)
  end

  defp echo(i, suffix), do: {:resolve, AshBulkDurable.EchoResolver, "AR #{i}-#{suffix}"}

  defp subscribe(bulk_action) do
    topic = "bulk_action:#{bulk_action.id}"
    :ok = PubSub.subscribe(topic)
    topic
  end

  # Every message on the topic, in order, once the run has returned.
  defp drain_topic(topic, acc \\ []) do
    receive do
      {^topic, "progress", payload} ->
        drain_topic(topic, [{:progress, payload} | acc])

      {^topic, _event, %Ash.Notifier.Notification{data: data}} ->
        drain_topic(topic, [{:update, data} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp hints(messages, phase),
    do: for({:progress, %{phase: ^phase} = payload} <- messages, do: payload)

  describe "an all-or-nothing write" do
    test "sends uncommitted hints before its commit, rising and never past total_rows",
         %{super_user: user} do
      put_config(:progress_interval, 0)
      bulk_action = create_bulk_action!(region_rows(250), user.id, :all_or_nothing)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      messages = drain_topic(topic)
      writing = hints(messages, :writing)

      # One per slice of Ash's stream (100 rows by default).
      assert Enum.map(writing, & &1.rows_processed) == [100, 200, 250]

      for hint <- writing do
        assert %{
                 bulk_action_id: id,
                 pass: 0,
                 committed: false,
                 total_rows: 250
               } = hint

        assert id == bulk_action.id
      end

      # The hints come before the commit's own announcement of the rows.
      first_hint = Enum.find_index(messages, &match?({:progress, %{phase: :writing}}, &1))

      committed =
        Enum.find_index(messages, fn
          {:update, %{rows_done: rows_done}} -> rows_done > 0
          _other -> false
        end)

      assert first_hint < committed
      assert {:update, %{status: :completed}} = List.last(messages)
    end

    test "sends one hint per interval", %{super_user: user} do
      put_config(:progress_interval, 60_000)
      bulk_action = create_bulk_action!(region_rows(250), user.id, :all_or_nothing)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [%{rows_processed: 100}] = topic |> drain_topic() |> hints(:writing)
    end

    test "a per-row run sends none", %{super_user: user} do
      put_config(:progress_interval, 0)
      bulk_action = create_bulk_action!(region_rows(120), user.id, :per_row)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [] = topic |> drain_topic() |> hints(:writing)
    end

    test "the default interval still sends the first", %{super_user: user} do
      Application.delete_env(:ash_bulk_durable, :progress_interval)
      bulk_action = create_bulk_action!(region_rows(150), user.id, :all_or_nothing)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [%{rows_processed: 100} | _] = topic |> drain_topic() |> hints(:writing)
    end
  end

  describe "phase 1" do
    test "sends committed rows_resolved hints for every row at interval 0",
         %{super_user: user} do
      put_config(:progress_interval, 0)
      bulk_action = create_bulk_action!(region_rows(4, native: &echo/2), user.id, :per_row)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      resolving = topic |> drain_topic() |> hints(:resolving)

      # Each row, then the last again, always.
      assert Enum.map(resolving, & &1.rows_resolved) == [1, 2, 3, 4, 4]

      for hint <- resolving do
        assert %{committed: true, rows_to_resolve: 4, pass: 0} = hint
        assert hint.bulk_action_id == bulk_action.id
      end
    end

    test "the throttle holds, and the last is always sent", %{super_user: user} do
      put_config(:progress_interval, 60_000)
      bulk_action = create_bulk_action!(region_rows(5, native: &echo/2), user.id, :per_row)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [%{rows_resolved: 1}, %{rows_resolved: 5, rows_to_resolve: 5}] =
               topic |> drain_topic() |> hints(:resolving)
    end

    test "counts rows that fail to resolve", %{super_user: user} do
      put_config(:progress_interval, 0)

      native = fn
        1, _suffix -> {:resolve, FailingResolver, "x"}
        i, suffix -> echo(i, suffix)
      end

      bulk_action = create_bulk_action!(region_rows(3, native: native), user.id, :per_row)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [%{rows_resolved: 3, rows_to_resolve: 3} | _] =
               topic |> drain_topic() |> hints(:resolving) |> Enum.reverse()

      assert Ash.get!(BulkAction, bulk_action.id, authorize?: false).status ==
               :completed_with_errors
    end

    test "sends nothing with no row to resolve", %{super_user: user} do
      put_config(:progress_interval, 0)
      bulk_action = create_bulk_action!(region_rows(3), user.id, :per_row)
      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [] = topic |> drain_topic() |> hints(:resolving)
    end

    test "the hints come before an all-or-nothing write's", %{super_user: user} do
      put_config(:progress_interval, 0)

      bulk_action =
        create_bulk_action!(region_rows(3, native: &echo/2), user.id, :all_or_nothing)

      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [
               %{phase: :resolving, rows_resolved: 1},
               %{phase: :resolving, rows_resolved: 2},
               %{phase: :resolving, rows_resolved: 3},
               %{phase: :resolving, rows_resolved: 3},
               %{phase: :writing, rows_processed: 3, total_rows: 3}
             ] = for({:progress, payload} <- drain_topic(topic), do: payload)
    end
  end

  describe "the run's end" do
    test "leaves nothing in the process that ran it", %{super_user: user} do
      put_config(:progress_interval, 60_000)

      bulk_action =
        create_bulk_action!(region_rows(2, native: &echo/2), user.id, :all_or_nothing)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [] =
               for(
                 {key, _value} <- Process.get(),
                 is_tuple(key) and elem(key, 0) == AshBulkDurable.Core.Progress,
                 do: key
               )
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()
      handler_id = "progress-test-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ash_bulk_durable, :all_or_nothing, :progress],
          [:ash_bulk_durable, :phase1, :progress]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "reports each hint, with or without a pubsub", %{super_user: user} do
      put_config(:progress_interval, 60_000)
      put_config(:pubsub_module, nil)

      bulk_action =
        create_bulk_action!(region_rows(2, native: &echo/2), user.id, :all_or_nothing)

      id = bulk_action.id
      assert :ok = Worker.run_now(id)

      assert_received {:telemetry, [:ash_bulk_durable, :phase1, :progress],
                       %{rows_resolved: 1, rows_to_resolve: 2}, %{bulk_action_id: ^id, pass: 0}}

      assert_received {:telemetry, [:ash_bulk_durable, :phase1, :progress],
                       %{rows_resolved: 2, rows_to_resolve: 2}, %{bulk_action_id: ^id, pass: 0}}

      assert_received {:telemetry, [:ash_bulk_durable, :all_or_nothing, :progress],
                       %{rows_processed: 2, total_rows: 2}, %{bulk_action_id: ^id, pass: 0}}
    end
  end

  describe "best effort" do
    test "nothing is broadcast with no :pubsub_module", %{super_user: user} do
      put_config(:progress_interval, 0)
      put_config(:pubsub_module, nil)

      bulk_action =
        create_bulk_action!(region_rows(3, native: &echo/2), user.id, :all_or_nothing)

      topic = subscribe(bulk_action)

      assert :ok = Worker.run_now(bulk_action.id)

      assert [] = for({:progress, payload} <- drain_topic(topic), do: payload)
      assert Ash.get!(BulkAction, bulk_action.id, authorize?: false).status == :completed
    end

    test "a raising pubsub doesn't fail the run", %{super_user: user} do
      put_config(:progress_interval, 0)
      put_config(:pubsub_module, RaisingPubSub)

      for mode <- [:all_or_nothing, :per_row] do
        bulk_action = create_bulk_action!(region_rows(3, native: &echo/2), user.id, mode)

        assert :ok = Worker.run_now(bulk_action.id)

        fresh = Ash.get!(BulkAction, bulk_action.id, authorize?: false)
        assert fresh.status == :completed
        assert fresh.rows_done == 3
      end
    end
  end
end
