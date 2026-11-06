defmodule ExampleWeb.Scenarios.BulkLostWorkerScenarioTest do
  @moduledoc """
  The node running a bulk action dies. The bulk action stays `:running`, and
  its liveness hint (`alive_at`) stops moving: while the hint is fresh a
  poller leaves it alone, since it can't tell a dead run from a live one, and
  once the hint is older than the poller's `:stale_after` the poller runs the
  bulk action again, from what the dead run left, to its verdict. Nobody has
  to retry it.

  The worker is killed for real, between chunks (one killed inside a chunk's
  transaction would take the test's own shared connection down with it;
  `AshBulkDurable.Core.PollerTest` kills one there, on connections of its
  own). Ageing the hint stands in for minutes passing: the sandbox runs the
  whole test in one transaction, where the database's clock stands still. A
  slow run keeping its hint fresh is tested there too. Pulling the plug on a
  real node is the one thing a test can't do.

  `async: false`: telemetry handlers, the engine's config and the poller's
  name are global.
  """
  use ExampleWeb.ConnCase, async: false

  import Example.Test.StorageHelpers
  import Phoenix.LiveViewTest

  alias AshBulkDurable.Core.{Poller, Worker}
  alias Example.BulkActions.BulkAction
  alias Example.Repo
  alias Example.Test.Asset
  alias Example.Test.Region
  alias Example.Test.RoleTestHelpers

  require Ash.Query

  @moduletag :scenario

  @stale_after :timer.minutes(2)

  setup do
    put_storage(Example.Test.TestStorage)
    start_supervised!(Example.Test.TestStorage)
    put_config(:default_chunk_size, 1)
  end

  test "a sales officer watching the page sees a dead run resume once its hint goes stale",
       %{conn: conn, super_user: super_user} do
    organization = RoleTestHelpers.create_organization(super_user)

    officer =
      RoleTestHelpers.create_user_with_organization_role(super_user, organization, [
        :clerk
      ])

    serial = Enum.map(1..3, fn _n -> "SN#{:erlang.unique_integer([:positive])}" end)

    {view, bulk_action} =
      submit(conn, officer, "asset", """
      serial_number,batch_number,category,make
      #{Enum.map_join(serial, "\n", &"#{&1},EN#{&1},truck,Isuzu")}
      """)

    die(bulk_action, [:ash_bulk_durable, :chunk, :stop])
    assert view |> element("#bulk-action-panel") |> render() =~ "1 of 3 rows done"
    assert %{status: :running, rows_done: 1, alive_at: %DateTime{}} = reload(bulk_action)

    # Dead, but nobody can know yet: a poller leaves a run this recent alone.
    starts = count_starts(bulk_action)
    start_poller!()
    assert poll() == []
    assert starts.() == 0
    assert %{status: :running, rows_done: 1} = reload(bulk_action)

    stale!(bulk_action)
    assert poll() == [bulk_action.id]
    await_idle()

    assert starts.() == 1
    assert render(view) =~ "Completed"
    assert %{status: :completed, rows_done: 3} = reload(bulk_action)
    assert serial |> Enum.map(&asset_count(&1, officer)) == [1, 1, 1]
  end

  test "all or nothing: a run dead before it wrote starts over, and nothing is written twice",
       %{conn: conn, super_user: super_user} do
    code = "A#{:erlang.unique_integer([:positive])}"

    {view, bulk_action} =
      submit(
        conn,
        super_user,
        "region",
        "code,name,native_name\n#{code},N #{code},ا #{code}\n",
        %{"all_or_nothing" => "on"}
      )

    die(bulk_action, [:ash_bulk_durable, :phase1, :start])
    assert %{status: :running} = reload(bulk_action)
    assert region_count(code, super_user) == 0

    start_poller!()
    stale!(bulk_action)
    assert poll() == [bulk_action.id]
    await_idle()

    assert render(view) =~ "Completed"
    assert %{status: :completed} = reload(bulk_action)
    assert region_count(code, super_user) == 1
  end

  @doc false
  def run_for(_event, _measurements, %{bulk_action_id: id}, {id, {module, function, args}}),
    do: apply(module, function, args)

  def run_for(_event, _measurements, _metadata, _config), do: :ok

  # The node's own run, killed at `event`.
  defp die(bulk_action, event) do
    handler = attach(event, %{id: bulk_action.id}, {__MODULE__, :kill_self, []})

    {worker, monitor} = spawn_monitor(fn -> Worker.run_now(bulk_action.id) end)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5000
    :telemetry.detach(handler)
  end

  @doc false
  def kill_self, do: Process.exit(self(), :kill)

  defp attach(event, %{id: id}, call) do
    handler = "bulk-lost-worker-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, &__MODULE__.run_for/4, {id, call})
    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  # How many runs of the bulk action started.
  defp count_starts(bulk_action) do
    counter = :counters.new(1, [])
    handler = "bulk-lost-worker-starts-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ash_bulk_durable, :worker_attempt, :start],
      fn _event, _measurements, %{bulk_action_id: id}, _config ->
        if id == bulk_action.id, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    fn -> :counters.get(counter, 1) end
  end

  # Another node's poller, as it would run beside this one. It polls only
  # when told, and starts no sweep.
  defp start_poller!(opts \\ []) do
    start_supervised!(
      {Poller,
       Keyword.merge(
         [
           poll_interval: :timer.hours(1),
           stale_after: @stale_after,
           staging_sweep_interval: nil,
           shutdown_grace: 1_000
         ],
         opts
       )}
    )
  end

  # The bulk actions a poll started.
  defp poll do
    Poller.nudge()
    Poller.running()
  end

  defp await_idle(tries \\ 250) do
    cond do
      Poller.running() == [] -> :ok
      tries == 0 -> flunk("the poller's runs didn't end")
      true -> Process.sleep(20) && await_idle(tries - 1)
    end
  end

  # Its hint as minutes of silence would leave it.
  defp stale!(bulk_action) do
    Repo.query!(
      "UPDATE bulk_actions SET alive_at = alive_at - interval '10 minutes' WHERE id = $1",
      [Ecto.UUID.dump!(bulk_action.id)]
    )
  end

  defp submit(conn, user, resource, csv, form_params \\ %{}) do
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => resource})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => "create"})

    view
    |> file_input("#main_form", :sheet, [%{name: "sheet.csv", content: csv, type: "text/csv"}])
    |> render_upload("sheet.csv")

    view |> form("#main_form", form_params) |> render_submit()
    render_async(view, 2000)

    bulk_action =
      BulkAction
      |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user.id})
      |> Ash.read_one!(authorize?: false)

    {view, bulk_action}
  end

  defp reload(%BulkAction{id: id}), do: Ash.get!(BulkAction, id, authorize?: false)

  defp region_count(code, user) do
    Region |> Ash.Query.filter(code == ^code) |> Ash.count!(actor: user)
  end

  defp asset_count(serial, user) do
    Asset |> Ash.Query.filter(serial_number == ^serial) |> Ash.count!(actor: user)
  end
end
