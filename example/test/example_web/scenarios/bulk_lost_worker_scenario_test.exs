defmodule ExampleWeb.Scenarios.BulkLostWorkerScenarioTest do
  @moduledoc """
  The node running a bulk action dies. Nothing moves its Oban job off
  `:executing`, so the run looks alive until the job's silence gives it away:
  then the page says it stopped, the owner's slot is free, and a retry runs only
  what the dead node left. A slow run that is still beating is left alone.

  The worker is killed for real, after a chunk committed, and the job's silence
  stands in for five minutes passing. Pulling the plug on a real node is the
  one thing a test can't do; that was done by hand (`kill -9`).

  `async: false`: telemetry handlers and the engine's config are global.
  """
  use ExampleWeb.ConnCase, async: false
  use Oban.Testing, repo: Example.Repo

  import Example.Test.StorageHelpers
  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias AshBulkDurable.Core.{RescueStuckBulkActions, Worker}
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

  test "a sales officer watching the page sees the cron free a dead run, and the retry finishes it",
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

    job = job_running(bulk_action)
    die(job, [:ash_bulk_durable, :chunk, :stop])

    # Dead, but nobody can know yet: a run this recent keeps its slot.
    assert :ok = perform_job(RescueStuckBulkActions, %{})
    assert view |> element("#bulk-action-panel") |> render() =~ "1 of 3 rows done"
    assert %{status: :running, rows_done: 1} = reload(bulk_action)

    silent_for_ages(job)
    assert :ok = perform_job(RescueStuckBulkActions, %{})

    html = render(view)
    assert html =~ @stopped
    assert html =~ @go_to_retry
    refute html =~ "start it again with the same settings"
    assert %{state: "cancelled"} = Repo.reload!(job)

    retry(view, bulk_action)
    assert %{status: :completed, rows_done: 3} = reload(bulk_action)

    assert serial |> Enum.map(&asset_count(&1, officer)) == [1, 1, 1]
  end

  test "a super user coming back to the page frees a dead run without waiting for the cron",
       %{conn: conn, super_user: super_user} do
    codes = Enum.map(1..3, fn _n -> "L#{:erlang.unique_integer([:positive])}" end)

    {_view, bulk_action} =
      submit(conn, super_user, "region", """
      code,name,native_name
      #{Enum.map_join(codes, "\n", &"#{&1},Name #{&1},اسم #{&1}")}
      """)

    job = job_running(bulk_action)
    die(job, [:ash_bulk_durable, :chunk, :stop])
    silent_for_ages(job)

    {:ok, view, html} = conn |> login_as(super_user) |> live(~p"/bulk")
    assert html =~ @stopped

    retry(view, bulk_action)
    assert %{status: :completed, rows_done: 3} = reload(bulk_action)

    assert codes |> Enum.map(&region_count(&1, super_user)) == [1, 1, 1]
  end

  test "all or nothing: a run dead before it wrote leaves the owner free to submit another",
       %{conn: conn, super_user: super_user} do
    code = "A#{:erlang.unique_integer([:positive])}"

    {view, bulk_action} =
      submit(
        conn,
        super_user,
        "region",
        "code,name,native_name\n#{code},N #{code},ا #{code}\n",
        %{
          "all_or_nothing" => "on"
        }
      )

    job = job_running(bulk_action)
    die(job, [:ash_bulk_durable, :chunk, :start])
    silent_for_ages(job)

    assert :ok = perform_job(RescueStuckBulkActions, %{})
    assert render(view) =~ @stopped
    assert region_count(code, super_user) == 0

    view |> element("#bulk-action-panel button", "Dismiss") |> render_click()

    {_view, next} =
      submit(conn, super_user, "region", "code,name,native_name\n#{code},N #{code},ا #{code}\n")

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
    assert %{status: :completed} = reload(next)
    assert region_count(code, super_user) == 1
  end

  test "a slow run outlasting the limit keeps beating, and the cron leaves it alone",
       %{conn: conn, super_user: super_user} do
    put_config(:worker_lost_after, 300)
    code = "S#{:erlang.unique_integer([:positive])}"

    {view, bulk_action} =
      submit(conn, super_user, "region", "code,name,native_name\n#{code},N #{code},ا #{code}\n")

    job = job_running(bulk_action)
    attach([:ash_bulk_durable, :chunk, :start], %{id: bulk_action.id}, {Process, :sleep, [900]})
    {worker, monitor} = spawn_monitor(fn -> Worker.perform(job) end)

    Process.sleep(600)
    assert :ok = perform_job(RescueStuckBulkActions, %{})
    assert reload(bulk_action).status == :running
    assert Process.alive?(worker)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5000
    assert render(view) =~ "Completed"
    assert %{status: :completed} = reload(bulk_action)
  end

  test "a beat that can't be written costs the run nothing",
       %{conn: conn, super_user: super_user} do
    put_config(:worker_lost_after, 100)

    for {break_the_beat, reason} <- [
          {&delete_job/1, "missed a heartbeat: :locked_or_not_found"},
          {&raising_beat/1, "missed a heartbeat: %BadMapError"}
        ] do
      code = "B#{:erlang.unique_integer([:positive])}"

      {_view, bulk_action} =
        submit(
          conn,
          super_user,
          "region",
          "code,name,native_name\n#{code},N #{code},ا #{code}\n"
        )

      job = bulk_action |> job_running() |> break_the_beat.()
      attach([:ash_bulk_durable, :chunk, :start], %{id: bulk_action.id}, {Process, :sleep, [100]})

      log =
        capture_log(fn ->
          {worker, monitor} = spawn_monitor(fn -> Worker.perform(job) end)
          assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5000
        end)

      assert log =~ "Bulk action job #{job.id} #{reason}"
      assert %{status: :completed} = reload(bulk_action)
    end
  end

  @doc false
  def run_for(_event, _measurements, %{bulk_action_id: id}, {id, {module, function, args}}),
    do: apply(module, function, args)

  def run_for(_event, _measurements, _metadata, _config), do: :ok

  # Oban, had it picked the job up: no queue runs in a test.
  defp job_running(bulk_action) do
    from(j in Oban.Job, where: j.id == ^bulk_action.oban_job_id)
    |> Repo.update_all(set: [state: "executing", attempted_at: DateTime.utc_now()])

    Repo.get!(Oban.Job, bulk_action.oban_job_id)
  end

  defp die(job, event) do
    %{"bulk_action_id" => id} = job.args
    handler = attach(event, %{id: id}, {__MODULE__, :kill_self, []})

    {worker, monitor} = spawn_monitor(fn -> Worker.perform(job) end)
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

  defp delete_job(job), do: Repo.delete!(job)

  # A database that is really down keeps a beat in Oban's own retries for
  # seconds before it raises.
  defp raising_beat(job), do: %{job | meta: nil}

  defp silent_for_ages(job) do
    from(j in Oban.Job, where: j.id == ^job.id)
    |> Repo.update_all(set: [attempted_at: DateTime.add(DateTime.utc_now(), -6, :minute)])
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
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
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
