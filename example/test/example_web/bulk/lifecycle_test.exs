defmodule ExampleWeb.Bulk.LifecycleTest do
  @moduledoc """
  Step 9 (#41) durability suite for `/bulk`. Unlike
  `DurableBulkActionTest` — which exercises the LV wiring with manually-flipped
  bulk action states — these tests drive the **real** `AshBulkDurable.Core.Worker`
  through `AshBulkDurable.Core.Worker.drain/0`, proving the durability claims
  the whole design exists to provide:

    * a submitted bulk action completes even after its LiveView is killed;
    * a reconnecting user re-renders the bulk action from persisted DB state;
    * a crashed worker resumes from the next pending row with no
      no row committed twice;
    * the one-unresolved rule blocks a second submit (and a second job);
    * abandoning a `:completed_with_errors` bulk action enqueues the eager
      staging purge.

  Nothing here is global, so it runs `async: true`: the `start_async` submit
  and the phase-1 `Task.async_stream` children reach the test's sandbox
  connection through `$callers`, the drain bulk actions in the test process, and each
  test's `oban_jobs` rows are confined to its own sandbox transaction.
  """
  use ExampleWeb.ConnCase, async: true
  use Oban.Testing, repo: Example.Repo

  import Phoenix.LiveViewTest

  require Ash.Query

  alias AshBulkDurable.Core.{Worker, PurgeStaleStaging}
  alias Example.BulkActions.{BulkAction, Row}
  alias Example.Test.Region
  alias NimbleCSV.RFC4180, as: CSV

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp unresolved_bulk_action(user_id) do
    BulkAction
    |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user_id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload(%BulkAction{id: id}), do: Ash.get!(BulkAction, id, authorize?: false)

  # `code`, `name` and `native_name` are each a unique identity on Region, so
  # literal rows would have two async tests queue on the same three index keys
  # once both drain their bulk actions.
  defp region_rows do
    tag = "T#{System.unique_integer([:positive])}"

    Enum.map(1..3, fn n ->
      %{code: "#{tag}#{n}", name: "Region #{tag}#{n}", native_name: "منطقة #{tag}#{n}"}
    end)
  end

  defp to_csv(rows) do
    ["code,name,native_name" | Enum.map(rows, &"#{&1.code},#{&1.name},#{&1.native_name}")]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp list_rows(bulk_action_id) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  # Stages a sheet as `/bulk`'s submit does (no LV), for tests that need to
  # inject partial / terminal state.
  defp create_bulk_action!(user_id) do
    tag = "T#{System.unique_integer([:positive])}"

    mapping = %AshBulkDurable.Sheet.Mapping{
      resource: Region,
      action: Ash.Resource.Info.action(Region, :create),
      columns: %{name: "name", native_name: "native_name", code: "code"}
    }

    rows =
      Enum.map(
        1..5,
        &%{
          "name" => "Region #{tag}#{&1}",
          "native_name" => "AR #{tag}#{&1}",
          "code" => "#{tag}#{&1}"
        }
      )

    {:ok, bulk_action} =
      AshBulkDurable.Sheet.stage(rows, mapping,
        scope: AshBulkDurable.Core.Owner.scope_from_worker_key(user_id, nil),
        chunk_size: 2
      )

    bulk_action
  end

  defp drain, do: Worker.drain()

  # Kill the LiveView process to simulate a dropped/closed tab. The test
  # process is linked to the LV and owns the sandbox connection, so trap exits
  # first — otherwise the propagated `:kill` would take the test (and its DB
  # connection) down with it.
  defp kill(pid) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end

  # Drive the LV form to a submittable state: pick Region/create and upload
  # the CSV so `uploaded_file` is populated and the fields auto-map.
  defp ready_to_submit(view, rows \\ region_rows(), csv \\ &to_csv/1) do
    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => "region"})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => "create"})

    file =
      file_input(view, "#main_form", :sheet, [
        %{name: "regions.csv", content: csv.(rows), type: "text/csv"}
      ])

    render_upload(file, "regions.csv")
    view
  end

  defp submit_bulk_action(conn, user, rows \\ region_rows(), csv \\ &to_csv/1) do
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

    view
    |> ready_to_submit(rows, csv)
    |> form("#main_form")
    |> render_submit()

    render_async(view, 2000)
    {view, unresolved_bulk_action(user.id)}
  end

  # ── Submit happy path (drives the real worker) ────────────────────────────

  describe "submit happy path" do
    test "enqueues a job, drains it to completion, renders :completed", %{
      conn: conn,
      super_user: user
    } do
      rows = region_rows()
      codes = Enum.map(rows, & &1.code)
      {view, bulk_action} = submit_bulk_action(conn, user, rows)
      assert bulk_action.status == :queued
      assert_enqueued(worker: Worker, args: %{bulk_action_id: bulk_action.id})

      # One Oban job (the bulk action worker) drains successfully.
      assert 1 = drain()

      fresh = reload(bulk_action)
      assert fresh.status == :completed
      assert fresh.rows_done == 3

      # The still-attached LV picked up the terminal broadcast.
      html = render(view)
      assert html =~ "Completed"
      assert html =~ "Dismiss"

      assert Region
             |> Ash.Query.filter(code in ^codes)
             |> Ash.read!(actor: user, authorize?: false)
             |> length() == 3
    end
  end

  # Excel saves a CSV with a UTF-8 byte-order mark before its first header,
  # which left that column named "\uFEFFcode" and never mapped to `code`.
  describe "a sheet Excel saved" do
    test "maps its first column despite the byte-order mark", %{conn: conn, super_user: user} do
      rows = region_rows()
      codes = Enum.map(rows, & &1.code)

      {view, bulk_action} = submit_bulk_action(conn, user, rows, &("\uFEFF" <> to_csv(&1)))
      assert 1 = drain()

      assert reload(bulk_action).status == :completed
      assert render(view) =~ "Completed"

      assert Region
             |> Ash.Query.filter(code in ^codes)
             |> Ash.read!(authorize?: false)
             |> length() == 3
    end
  end

  # A sheet exactly one chunk long once read as all-or-nothing, because the
  # mode was inferred from `chunk_size == total_rows`.
  describe "a per-row sheet exactly one chunk long" do
    test "commits its good rows and keeps the bad one to correct", %{
      conn: conn,
      super_user: user
    } do
      tag = "T#{System.unique_integer([:positive])}"
      chunk_size = AshBulkDurable.config(:default_chunk_size, 50)

      rows =
        Enum.map(1..chunk_size, fn n ->
          %{code: "#{tag}#{n}", name: "Region #{tag}#{n}", native_name: "منطقة #{tag}#{n}"}
        end)

      # The last row reuses the first row's code, so only it can fail.
      rows = List.update_at(rows, -1, &%{&1 | code: "#{tag}1"})

      {view, bulk_action} = submit_bulk_action(conn, user, rows)
      assert 1 = drain()

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == chunk_size - 1

      html = render(view)
      assert html =~ "Completed with errors"
      assert html =~ "Download errors sheet"

      assert Region
             |> Ash.Query.filter(contains(code, ^tag))
             |> Ash.read!(authorize?: false)
             |> length() == chunk_size - 1
    end
  end

  # ── Destroying by sheet ───────────────────────────────────────────────────

  # Existing regions the sheet will name by code, plus a code no
  # region has, so exactly one row can fail.
  defp destroy_fixture(user) do
    existing =
      Enum.map(region_rows(), fn attrs ->
        Ash.create!(Region, attrs, actor: user, authorize?: false)
      end)

    missing = "MISSING#{System.unique_integer([:positive])}"
    {existing, missing}
  end

  defp submit_destroy(conn, user, codes, form_params) do
    submit_by_code(conn, user, "destroy", Enum.join(["code" | codes], "\n"), form_params)
  end

  defp submit_by_code(conn, user, action, csv, form_params) do
    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => "region"})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => action})

    view
    |> element("#main_form select[name=identity_name]")
    |> render_change(%{"identity_name" => "code"})

    file =
      file_input(view, "#main_form", :sheet, [
        %{
          name: "regions.csv",
          content: csv <> "\n",
          type: "text/csv"
        }
      ])

    render_upload(file, "regions.csv")

    view |> form("#main_form", form_params) |> render_submit()
    render_async(view, 2000)
    {view, unresolved_bulk_action(user.id)}
  end

  defp regions_left(existing) do
    ids = Enum.map(existing, & &1.id)

    Region
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  describe "destroying by sheet" do
    test "per row: deletes what it finds and keeps the row it can't to correct", %{
      conn: conn,
      super_user: user
    } do
      {existing, missing} = destroy_fixture(user)
      codes = Enum.map(existing, & &1.code) ++ [missing]

      {view, bulk_action} = submit_destroy(conn, user, codes, %{})
      assert bulk_action.action_type == :destroy
      assert bulk_action.mode == :per_row
      assert 1 = drain()

      fresh = reload(bulk_action)
      assert fresh.status == :completed_with_errors
      assert fresh.rows_done == length(existing)
      assert regions_left(existing) == 0

      [failed] = bulk_action.id |> list_rows() |> Enum.filter(&(&1.status == :failed))
      assert failed.metadata["code"] == missing

      html = render(view)
      assert html =~ "Completed with errors"
      assert html =~ missing
      assert html =~ "Code: could not be found"
      refute html =~ "not_found"
      assert html =~ "Download errors sheet"
    end

    test "all or nothing: one row it can't find keeps every record", %{
      conn: conn,
      super_user: user
    } do
      {existing, missing} = destroy_fixture(user)
      codes = Enum.map(existing, & &1.code) ++ [missing]

      {view, bulk_action} = submit_destroy(conn, user, codes, %{"all_or_nothing" => "on"})
      assert bulk_action.mode == :all_or_nothing
      assert 1 = drain()

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.rows_done == 0
      assert regions_left(existing) == length(existing)

      html = render(view)
      assert html =~ "Failed"
      assert html =~ "Row #{length(codes)}: Code: could not be found"
      assert_error_on_row(fresh, missing)
    end
  end

  describe "updating by sheet" do
    test "all or nothing: one row it can't find is the row named, on the panel and the sheet", %{
      conn: conn,
      super_user: user
    } do
      {existing, missing} = destroy_fixture(user)
      codes = Enum.map(existing, & &1.code) ++ [missing]
      csv = Enum.map_join(codes, "\n", fn code -> "#{code},N#{code}" end)

      {view, bulk_action} =
        submit_by_code(conn, user, "update", "code,name\n" <> csv, %{"all_or_nothing" => "on"})

      assert bulk_action.action_type == :update
      assert 1 = drain()

      fresh = reload(bulk_action)
      assert fresh.status == :failed
      assert fresh.rows_done == 0
      assert render(view) =~ "Row #{length(codes)}: Code: could not be found"
      assert_error_on_row(fresh, missing)
    end
  end

  # The errors sheet as the page downloads it: every row, the error on `code`'s.
  defp assert_error_on_row(bulk_action, code) do
    csv =
      bulk_action
      |> ExampleWeb.Bulk.ErrorsSheet.build()
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    [headers | rows] = CSV.parse_string(csv, skip_headers: false)
    rows = Enum.map(rows, &Map.new(Enum.zip(headers, &1)))

    {[offending], others} = Enum.split_with(rows, &(&1["code"] == code))
    assert offending["last_error"] =~ "could not be found"
    assert others != []
    assert Enum.all?(others, &(&1["last_error"] == ""))
  end

  # ── Reconnect / crash durability ───────────────────────────────────

  describe "reconnect after the submitting LiveView dies" do
    test "drain before revisit: work completes in DB, slot frees, form is empty", %{
      conn: conn,
      super_user: user
    } do
      {view, bulk_action} = submit_bulk_action(conn, user)

      # The submitting LV dies (tab closed, node drop) before the worker runs.
      :ok = kill(view.pid)

      # The worker runs to completion with no LV attached — the durability claim.
      assert 1 = drain()
      assert reload(bulk_action).status == :completed

      # Reconnecting after completion: the slot is free (terminal status
      # releases it), so the user lands on the empty form, not a stale panel.
      {:ok, view2, _html} = conn |> login_as(user) |> live(~p"/bulk")
      refute render(view2) =~ "bulk-action-panel"
      assert is_nil(unresolved_bulk_action(user.id))
    end

    test "drain after revisit: reconnect re-attaches the in-flight bulk action, PubSub completes it",
         %{conn: conn, super_user: user} do
      {view, bulk_action} = submit_bulk_action(conn, user)
      :ok = kill(view.pid)

      # Reconnect while the bulk action is still in flight (queued) — mount re-attaches
      # from the persisted DB state and subscribes to the bulk action topic.
      {:ok, view2, _html} = conn |> login_as(user) |> live(~p"/bulk")
      assert render(view2) =~ "bulk-action-panel"

      # Now the worker runs; its terminal broadcast reaches the reconnected LV.
      assert 1 = drain()
      assert reload(bulk_action).status == :completed

      html = render(view2)
      assert html =~ "Completed"
      assert html =~ "Dismiss"
    end
  end

  describe "crash-resume" do
    test "resumes from the next pending row on retry, no row committed twice", %{super_user: user} do
      bulk_action = create_bulk_action!(user.id)

      # Simulate a crash after rows 1..2 committed on a previous attempt:
      # mark them :succeeded with known record_ids and bump the bulk action counter.
      list_rows(bulk_action.id)
      |> Enum.take(2)
      |> Enum.with_index()
      |> Enum.each(fn {row, idx} ->
        Ash.update!(row, %{record_id: "stub-#{idx}"}, action: :mark_succeeded, authorize?: false)
      end)

      bulk_action
      |> Ash.Changeset.for_update(:bump_rows_done, %{n: 2}, authorize?: false)
      |> Ash.update!(authorize?: false)

      Ash.update!(bulk_action, %{}, action: :mark_running, authorize?: false)

      # The retry (the job the :create enqueued) drains and resumes at row 3.
      drain()

      fresh = reload(bulk_action)
      assert fresh.status == :completed
      assert fresh.rows_done == 5

      [r1, r2, r3, r4, r5] = list_rows(bulk_action.id)
      assert r1.record_id == "stub-0"
      assert r2.record_id == "stub-1"

      assert Enum.all?([r3, r4, r5], fn row ->
               row.status == :succeeded and is_binary(row.record_id) and
                 not String.starts_with?(row.record_id, "stub-")
             end)

      # Only rows 3..5 created real Regions — rows 1..2 were never re-applied.
      # Counted by this bulk action's own codes: the fixture's region is there too.
      codes = Enum.map([r1, r2, r3, r4, r5], & &1.input.code)

      assert Region
             |> Ash.Query.filter(code in ^codes)
             |> Ash.read!(actor: user, authorize?: false)
             |> length() == 3
    end
  end

  # ── One-in-flight enforcement ──────────────────────────────────────

  describe "second submit while a bulk action is in flight" do
    test "surfaces the flash and enqueues no second job", %{conn: conn, super_user: user} do
      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
      view |> ready_to_submit()

      # A competing bulk action appears after this LV mounted (so mount didn't attach
      # it); the submit's create then hits the partial unique index.
      create_bulk_action!(user.id)
      jobs_before = Example.Repo.aggregate(Oban.Job, :count, :id)

      view |> form("#main_form") |> render_submit()
      render_async(view, 2000)

      assert render(view) =~ "You have an unfinished bulk action."
      refute render(view) =~ "bulk-action-panel"
      assert Example.Repo.aggregate(Oban.Job, :count, :id) == jobs_before
    end
  end

  # ── :completed_with_errors → Abandon ───────────────────────

  describe "abandon failed rows" do
    test "shows the three controls, then cancels without enqueueing a staging purge", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)

      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
      assert render(view) =~ "bulk-action-panel"

      # Worker lands the bulk action in :completed_with_errors; the attached LV updates
      # via PubSub and the panel swaps to the errors-sheet controls.
      Ash.update!(bulk_action, %{result: :completed_with_errors},
        action: :mark_finished,
        authorize?: false
      )

      html = render(view)
      assert html =~ "Completed with errors"
      assert html =~ "Download errors sheet"
      assert html =~ "Upload corrections to retry"
      assert html =~ "Abandon failed rows"

      view |> element("#bulk-action-panel button", "Abandon failed rows") |> render_click()

      assert_patch(view, "/bulk")
      assert reload(bulk_action).status == :cancelled
      # The cancel deletes its staged files itself; no Oban job does it.
      refute_enqueued(worker: PurgeStaleStaging)
    end
  end

  # ── A parked bulk action the app has moved on from ────────────────

  describe "a parked bulk action whose resource or action is gone" do
    # A deploy that renames either leaves the stored name naming nothing, which
    # only the column itself can reproduce.
    defp rename_stored!(bulk_action, column, name) do
      Example.Repo.query!("UPDATE bulk_actions SET #{column} = $1 WHERE id = $2", [
        name,
        Ecto.UUID.dump!(bulk_action.id)
      ])
    end

    test "still opens /bulk, so its owner can abandon it and start another", %{
      conn: conn,
      super_user: user
    } do
      for {column, name} <- [
            {"resource_name", "MyApp.NoLongerHere"},
            {"action_name", "promote_to_super"},
            {"action_name", "gone_#{System.unique_integer([:positive])}"}
          ] do
        [first, second, _third] = region_rows()

        {_view, bulk_action} =
          submit_bulk_action(conn, user, [first, %{second | code: first.code}])

        assert 1 = drain()
        assert reload(bulk_action).status == :completed_with_errors

        rename_stored!(bulk_action, column, name)

        {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
        html = render(view)
        assert html =~ "Completed with errors"
        assert html =~ "Abandon failed rows"

        view |> element("#bulk-action-panel button", "Abandon failed rows") |> render_click()

        assert_patch(view, "/bulk")
        assert reload(bulk_action).status == :cancelled
      end

      {_view, next} = submit_bulk_action(conn, user)
      assert next.status == :queued
    end

    # A deploy that removes a field takes its atom with it, so `:safe` refuses
    # what was stored under it. A term naming an atom no module holds, built by
    # hand: spelling it in Elixir would create it.
    defp term_with_vanished_atom do
      name = "vanished_field_#{System.unique_integer([:positive])}"
      <<131, ?t, 1::32, 119, byte_size(name), name::binary, ?m, 1::32, "x">>
    end

    defp store_vanished!(table, column, id) do
      Example.Repo.query!("UPDATE #{table} SET #{column} = $1 WHERE id = $2", [
        term_with_vanished_atom(),
        Ecto.UUID.dump!(id)
      ])
    end

    test "with an input holding a vanished atom still opens /bulk, to abandon", %{
      conn: conn,
      super_user: user
    } do
      for {table, column} <- [{:row, "input"}, {:row, "target"}, {:bulk_action, "input"}] do
        [first, second, _third] = region_rows()

        {_view, bulk_action} =
          submit_bulk_action(conn, user, [first, %{second | code: first.code}])

        assert 1 = drain()
        [_good, failed] = list_rows(bulk_action.id)

        case table do
          :row -> store_vanished!("bulk_action_rows", column, failed.id)
          :bulk_action -> store_vanished!("bulk_actions", column, bulk_action.id)
        end

        {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
        assert render(view) =~ "Abandon failed rows"

        view |> element("#bulk-action-panel button", "Abandon failed rows") |> render_click()
        assert_patch(view, "/bulk")
        assert reload(bulk_action).status == :cancelled
      end
    end

    test "with a row holding a vanished atom refuses its retry and errors sheet, keeping the page",
         %{conn: conn, super_user: user} do
      [first, second, _third] = region_rows()
      {_view, bulk_action} = submit_bulk_action(conn, user, [first, %{second | code: first.code}])
      assert 1 = drain()
      [_good, failed] = list_rows(bulk_action.id)
      store_vanished!("bulk_action_rows", "input", failed.id)

      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      view |> element("button", "Download errors sheet") |> render_click()
      assert render_async(view, 1000) =~ "prepare the errors sheet"
      view |> element("button[aria-label=Close]") |> render_click()

      view
      |> file_input("#retry-upload-form", :retry_csv, [
        %{
          name: "corrections.csv",
          content: "row_id,last_error,code\n#{failed.id},,#{first.code}X\n",
          type: "text/csv"
        }
      ])
      |> render_upload("corrections.csv")

      view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()

      html = render(view)
      assert html =~ "no longer exists"
      assert html =~ "Abandon failed rows"
      assert reload(bulk_action).status == :completed_with_errors
    end

    test "with its own input or tenant holding a vanished atom refuses a retry as it is", %{
      conn: conn,
      super_user: user
    } do
      for column <- ["input", "tenant"] do
        [first, second, _third] = region_rows()

        {_view, bulk_action} =
          submit_bulk_action(conn, user, [first, %{second | code: first.code}])

        assert 1 = drain()
        store_vanished!("bulk_actions", column, bulk_action.id)

        assert {:error, :gone} =
                 AshBulkDurable.retry(reload(bulk_action),
                   scope: Example.Scope.new(actor: user)
                 )

        assert reload(bulk_action).status == :completed_with_errors

        assert {:ok, _abandoned} =
                 AshBulkDurable.abandon(reload(bulk_action),
                   scope: Example.Scope.new(actor: user)
                 )
      end
    end

    test "queued, a row holding a vanished atom fails alone and nothing runs without its input",
         %{
           conn: conn,
           super_user: user
         } do
      [first, second, third] = region_rows()
      {view, bulk_action} = submit_bulk_action(conn, user, [first, second, third])
      [_first, unreadable, _third] = list_rows(bulk_action.id)
      store_vanished!("bulk_action_rows", "input", unreadable.id)

      assert 1 = drain()

      assert reload(bulk_action).status == :completed_with_errors
      assert Enum.map(list_rows(bulk_action.id), & &1.status) == [:succeeded, :failed, :succeeded]
      assert render(view) =~ "What this row held no longer exists, so nothing was saved for it."
    end

    test "queued, all or nothing, a row holding a vanished atom stops it at that row", %{
      super_user: user
    } do
      [first, second, _third] = region_rows()

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([first, second], Region, :create,
          scope: Example.Scope.new(actor: user),
          mode: :all_or_nothing
        )

      [_first, unreadable] = list_rows(bulk_action.id)
      store_vanished!("bulk_action_rows", "input", unreadable.id)

      assert 1 = drain()

      assert %{status: :failed, result: %{"row_index" => 1}} = reload(bulk_action)
      assert Ash.read!(Region, authorize?: false) |> Enum.all?(&(&1.code != first.code))
    end

    test "queued, with a shared input holding a vanished atom, fails whole and runs nothing", %{
      conn: conn,
      super_user: user
    } do
      {_view, bulk_action} = submit_bulk_action(conn, user)
      store_vanished!("bulk_actions", "input", bulk_action.id)

      assert 1 = drain()

      assert reload(bulk_action).status == :failed
      assert Enum.all?(list_rows(bulk_action.id), &(&1.status != :succeeded))

      {:ok, view, _html} =
        conn |> login_as(user) |> live(~p"/bulk?bulk_action=#{bulk_action.id}")

      assert render(view) =~ "What this bulk action held no longer exists, so it can&#39;t run."
    end

    test "refuses its retry and its errors sheet without losing the page", %{
      conn: conn,
      super_user: user
    } do
      for {column, name} <- [
            {"resource_name", "MyApp.NoLongerHere"},
            {"action_name", "gone_#{System.unique_integer([:positive])}"}
          ] do
        [first, second, _third] = region_rows()

        {_view, bulk_action} =
          submit_bulk_action(conn, user, [first, %{second | code: first.code}])

        assert 1 = drain()
        [_good, failed] = list_rows(bulk_action.id)

        rename_stored!(bulk_action, column, name)

        {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

        view |> element("button", "Download errors sheet") |> render_click()
        assert render_async(view, 1000) =~ "prepare the errors sheet"
        view |> element("button[aria-label=Close]") |> render_click()

        view
        |> file_input("#retry-upload-form", :retry_csv, [
          %{
            name: "corrections.csv",
            content: "row_id,last_error,code\n#{failed.id},,#{first.code}X\n",
            type: "text/csv"
          }
        ])
        |> render_upload("corrections.csv")

        view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()

        html = render(view)
        assert html =~ "no longer exists"
        assert html =~ "Abandon failed rows"
        assert reload(bulk_action).status == :completed_with_errors

        view |> element("#bulk-action-panel button", "Abandon failed rows") |> render_click()
        assert reload(bulk_action).status == :cancelled
      end
    end
  end

  # ── Errors-sheet retry upload ─────────────────────────────────────

  describe "upload corrections to retry" do
    defp existing_codes(rows) do
      codes = Enum.map(rows, & &1.code)

      Region
      |> Ash.Query.filter(code in ^codes)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&to_string(&1.code))
    end

    # The sheet the panel's Download serves, as the user saves it after
    # editing: `edit` gets each row's cells.
    defp upload_corrected(view, bulk_action, edit) do
      csv =
        bulk_action
        |> ExampleWeb.Bulk.ErrorsSheet.build()
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      [headers | rows] = CSV.parse_string(csv, skip_headers: false)

      corrected =
        [headers | Enum.map(rows, &edit.(Map.new(Enum.zip(headers, &1))))]
        |> Enum.map(fn
          ^headers -> headers
          row -> Enum.map(headers, fn header -> Map.fetch!(row, header) end)
        end)
        |> CSV.dump_to_iodata()
        |> IO.iodata_to_binary()

      view
      |> file_input("#retry-upload-form", :retry_csv, [
        %{name: "corrections.csv", content: corrected, type: "text/csv"}
      ])
      |> render_upload("corrections.csv")
    end

    test "a row that failed per row is corrected in the sheet and runs again", %{
      conn: conn,
      super_user: user
    } do
      [good, taken, also_good] = rows = region_rows()
      Ash.create!(Region, taken, actor: user)

      {view, bulk_action} = submit_bulk_action(conn, user, rows)
      drain()

      html = render(view)
      assert html =~ "Completed with errors"
      assert html =~ "2 of 3 rows done"
      # The preview shows what the row held, by input.
      assert html =~ taken.name
      assert html =~ "Upload corrections to retry"

      assert Enum.sort(existing_codes([good, also_good])) ==
               Enum.sort([good.code, also_good.code])

      fixed_code = "T#{System.unique_integer([:positive])}"
      fixed_name = "Name #{fixed_code}"
      fixed_native_name = "اسم #{fixed_code}"

      upload_corrected(view, reload(bulk_action), fn row ->
        %{row | "code" => fixed_code, "name" => fixed_name, "native_name" => fixed_native_name}
      end)

      # Picking a file commits nothing.
      assert reload(bulk_action).status == :completed_with_errors
      html = render(view)
      assert html =~ "corrections.csv"
      assert html =~ "Retry failed rows"

      view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()

      assert render(view) =~ "Reopened 1 row for retry."
      assert reload(bulk_action).status == :running

      drain()

      assert render(view) =~ "3 of 3 rows done"
      assert reload(bulk_action).status == :completed
      assert existing_codes([%{code: fixed_code}]) == [fixed_code]
    end

    test "an all-or-nothing bulk action that rolled back is corrected and runs again whole", %{
      conn: conn,
      super_user: user
    } do
      [first, taken, third] = rows = region_rows()
      Ash.create!(Region, taken, actor: user)

      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      view
      |> ready_to_submit(rows)
      |> form("#main_form", %{"all_or_nothing" => "on"})
      |> render_submit()

      render_async(view, 2000)
      bulk_action = unresolved_bulk_action(user.id)
      drain()

      html = render(view)
      assert html =~ "rolled back"
      assert html =~ "Download errors sheet"
      assert html =~ "Upload corrections to retry"
      assert html =~ "Start again with same settings"
      refute html =~ "Abandon failed rows"
      assert existing_codes([first, third]) == []

      fixed_code = "T#{System.unique_integer([:positive])}"

      upload_corrected(view, reload(bulk_action), fn
        %{"code" => code} = row when code == taken.code ->
          %{
            row
            | "code" => fixed_code,
              "name" => "Name #{fixed_code}",
              "native_name" => "اسم #{fixed_code}"
          }

        row ->
          row
      end)

      view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
      assert render(view) =~ "Reopened 3 rows for retry."

      drain()

      assert reload(bulk_action).status == :completed

      assert Enum.sort(existing_codes([first, third, %{code: fixed_code}])) ==
               Enum.sort([first.code, third.code, fixed_code])
    end

    test "a sheet naming a row that is not this bulk action's changes nothing", %{
      conn: conn,
      super_user: user
    } do
      [_good, taken, _other] = rows = region_rows()
      Ash.create!(Region, taken, actor: user)

      {view, bulk_action} = submit_bulk_action(conn, user, rows)
      drain()
      render(view)

      upload_corrected(view, reload(bulk_action), &%{&1 | "row_id" => Ecto.UUID.generate()})
      view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()

      assert render(view) =~ "1 row didn&#39;t match the original bulk action."
      assert reload(bulk_action).status == :completed_with_errors
    end
  end
end
