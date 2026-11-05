defmodule ExampleWeb.Scenarios.BulkLostWorkerScenarioTest do
  @moduledoc """
  The node running a bulk action dies. Its claim holds the bulk action only
  until its lease runs out: then any node's next poll claims it again and the
  rows resume where the dead node left them, none run twice. A bulk action
  whose claims keep dying is failed for its owner to retry. A slow run keeps
  renewing its lease and is left alone; a run that lost its claim stops.

  The worker is killed for real, after a chunk committed, and an expired
  lease stands in for a minute passing. Pulling the plug on a real node is
  the one thing a test can't do; that was done by hand (`kill -9`).

  `async: false`: telemetry handlers and the engine's config are global.
  """
  use ExampleWeb.ConnCase, async: false

  import Example.Test.StorageHelpers
  import Phoenix.LiveViewTest

  alias AshBulkDurable.Core.{Lease, Worker}
  alias Example.BulkActions.BulkAction
  alias Example.Test.Asset
  alias Example.Repo
  alias Example.Test.Region
  alias Example.Test.RoleTestHelpers

  require Ash.Query

  @moduletag :scenario

  @stopped "The bulk action stopped before finishing."
  @go_to_retry "Rows already saved won&#39;t run again."

  setup do
    put_storage(Example.Test.TestStorage)
    start_supervised!(Example.Test.TestStorage)
    put_config(:default_chunk_size, 1)
  end

  test "a sales officer watching the page sees a dead run resume, no row run twice",
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

    # Dead, but nobody can know yet: its lease still holds it.
    assert :skipped = Worker.run_now(bulk_action.id)
    assert view |> element("#bulk-action-panel") |> render() =~ "1 of 3 rows done"
    assert %{status: :running, rows_done: 1, attempts: 1} = reload(bulk_action)

    lease_runs_out(bulk_action)
    assert %{success: 1, failure: 0} = Worker.drain()

    assert render(view) =~ "Completed"
    assert %{status: :completed, rows_done: 3, attempts: 2} = reload(bulk_action)
    assert serial |> Enum.map(&asset_count(&1, officer)) == [1, 1, 1]
  end

  test "a super user coming back to the page finds the dead run where it stopped",
       %{conn: conn, super_user: super_user} do
    codes = Enum.map(1..3, fn _n -> "L#{:erlang.unique_integer([:positive])}" end)

    {_view, bulk_action} =
      submit(conn, super_user, "region", """
      code,name,native_name
      #{Enum.map_join(codes, "\n", &"#{&1},Name #{&1},اسم #{&1}")}
      """)

    die(bulk_action, [:ash_bulk_durable, :chunk, :stop])
    lease_runs_out(bulk_action)

    {:ok, view, html} = conn |> login_as(super_user) |> live(~p"/bulk")
    assert html =~ "1 of 3 rows done"

    assert %{success: 1, failure: 0} = Worker.drain()
    assert render(view) =~ "Completed"
    assert codes |> Enum.map(&region_count(&1, super_user)) == [1, 1, 1]
  end

  test "all or nothing: a run dead before it wrote runs again whole",
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

    die(bulk_action, [:ash_bulk_durable, :chunk, :start])
    assert region_count(code, super_user) == 0

    lease_runs_out(bulk_action)
    assert %{success: 1, failure: 0} = Worker.drain()

    assert render(view) =~ "Completed"
    assert region_count(code, super_user) == 1
  end

  test "a run whose claims keep dying is failed, and a retry finishes it",
       %{conn: conn, super_user: super_user} do
    put_config(:max_attempts, 1)
    codes = Enum.map(1..2, fn _n -> "F#{:erlang.unique_integer([:positive])}" end)

    {view, bulk_action} =
      submit(conn, super_user, "region", """
      code,name,native_name
      #{Enum.map_join(codes, "\n", &"#{&1},Name #{&1},اسم #{&1}")}
      """)

    die(bulk_action, [:ash_bulk_durable, :chunk, :stop])
    lease_runs_out(bulk_action)

    assert %{success: 0, failure: 0} = Worker.drain()
    assert [_failed] = Lease.fail_exhausted()

    html = render(view)
    assert html =~ @stopped
    assert html =~ @go_to_retry
    refute html =~ "start it again with the same settings"

    retry(view, bulk_action)
    assert %{status: :completed, rows_done: 2} = reload(bulk_action)
    assert codes |> Enum.map(&region_count(&1, super_user)) == [1, 1]
  end

  test "a slow run outlasting its lease renews it, and no other claim takes it",
       %{conn: conn, super_user: super_user} do
    put_config(:lease_duration, 300)
    code = "S#{:erlang.unique_integer([:positive])}"

    {view, bulk_action} =
      submit(conn, super_user, "region", "code,name,native_name\n#{code},N #{code},ا #{code}\n")

    {:ok, claimed} = Lease.claim_one(bulk_action.id)
    attach([:ash_bulk_durable, :chunk, :start], %{id: bulk_action.id}, {Process, :sleep, [900]})
    {worker, monitor} = spawn_monitor(fn -> Worker.run(claimed) end)

    Process.sleep(600)
    assert :skipped = Worker.run_now(bulk_action.id)
    assert reload(bulk_action).claim_token == claimed.claim_token

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5000
    assert render(view) =~ "Completed"
    assert %{status: :completed} = reload(bulk_action)
  end

  test "a run whose claim another took over stops",
       %{conn: conn, super_user: super_user} do
    put_config(:lease_duration, 300)
    code = "T#{:erlang.unique_integer([:positive])}"

    {_view, bulk_action} =
      submit(conn, super_user, "region", "code,name,native_name\n#{code},N #{code},ا #{code}\n")

    {:ok, stale} = Lease.claim_one(bulk_action.id)
    attach([:ash_bulk_durable, :chunk, :start], %{id: bulk_action.id}, {Process, :sleep, [900]})
    {worker, monitor} = spawn_monitor(fn -> Worker.run(stale) end)

    # As though the stale run's renewals had stopped reaching the database.
    lease_runs_out(bulk_action)
    {:ok, current} = Lease.claim_one(bulk_action.id)

    assert_receive {:DOWN, ^monitor, :process, ^worker, {:lease_lost, _id}}, 5000
    assert region_count(code, super_user) == 0
    assert %{status: :running} = reload(bulk_action)

    :ok = Worker.run(current)
    assert %{status: :completed} = reload(bulk_action)
    assert region_count(code, super_user) == 1
  end

  @doc false
  def run_for(_event, _measurements, %{bulk_action_id: id}, {id, {module, function, args}}),
    do: apply(module, function, args)

  def run_for(_event, _measurements, _metadata, _config), do: :ok

  # A poll's claim, run in a process killed at `event`.
  defp die(bulk_action, event) do
    {:ok, claimed} = Lease.claim_one(bulk_action.id)
    handler = attach(event, %{id: bulk_action.id}, {__MODULE__, :kill_self, []})

    {worker, monitor} = spawn_monitor(fn -> Worker.run(claimed) end)
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

  defp lease_runs_out(bulk_action) do
    Repo.query!(
      "UPDATE bulk_actions SET lease_until = now() - interval '1 second' WHERE id = $1",
      [
        Ecto.UUID.dump!(bulk_action.id)
      ]
    )
  end

  defp retry(view, bulk_action) do
    csv =
      bulk_action
      |> ExampleWeb.Bulk.ErrorsSheet.build()
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    view
    |> file_input("#retry-upload-form", :retry_csv, [
      %{name: "corrections.csv", content: csv, type: "text/csv"}
    ])
    |> render_upload("corrections.csv")

    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
    assert %{success: 1, failure: 0} = Worker.drain()
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

  defp reload(%BulkAction{id: id}),
    do: Ash.get!(BulkAction, id, authorize?: false, load: [:rows_done, :rows_pending])

  defp region_count(code, user) do
    Region |> Ash.Query.filter(code == ^code) |> Ash.count!(actor: user)
  end

  defp asset_count(serial, user) do
    Asset |> Ash.Query.filter(serial_number == ^serial) |> Ash.count!(actor: user)
  end
end
