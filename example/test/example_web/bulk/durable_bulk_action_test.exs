defmodule ExampleWeb.Bulk.DurableBulkActionTest do
  @moduledoc """
  Step 6 (#38) coverage for the durable bulk action rewiring of `/bulk`:

    * Submit persists an `BulkAction` off the LV process via `start_async`,
      lands the URL on `?bulk_action=<id>`, and subscribes the LV to the bulk action's
      PubSub topic.
    * A second submit while the user already has an in-flight bulk action surfaces
      the one-in-flight flash.
    * Mount reattaches a logged-in user to their in-flight bulk action.
    * Mount flips a bulk action whose Oban job is in a terminal state to `:failed`
      (the stuck bulk action rescue), freeing the one-in-flight slot.
    * `dismiss_bulk_action` and `abandon_failed_rows` behave as designed.

  Nothing here is global, so it runs `async: true`: the LiveView carries the
  test pid in `$callers`, `start_async` spawns with `Task.start_link` which
  prepends to it, and the sandbox resolves the owner down that chain.
  """
  use ExampleWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Example.BulkActions.BulkAction

  # ── Helpers ────────────────────────────────────────────────────────────

  defp unresolved_bulk_action(user_id) do
    BulkAction
    |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user_id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload(%BulkAction{id: id}), do: Ash.get!(BulkAction, id, authorize?: false)

  # `code`, `name` and `native_name` are each a unique identity on Region, so a
  # literal row would have two async tests queue on the same three index keys
  # the moment either one applies its rows.
  defp region_csv do
    tag = "T#{System.unique_integer([:positive])}"

    """
    code,name,native_name
    #{tag}1,Region #{tag}1,منطقة #{tag}1
    #{tag}2,Region #{tag}2,منطقة #{tag}2
    #{tag}3,Region #{tag}3,منطقة #{tag}3
    """
  end

  # Persists an in-flight bulk action directly (no LV), as staging a sheet
  # would. Defaults to a chunked best-effort bulk action so the progress bar shows.
  defp create_bulk_action!(user_id, overrides \\ %{}) do
    tag = "T#{System.unique_integer([:positive])}"

    attrs =
      Map.merge(
        %{
          user_id: user_id,
          resource_name: "Example.Test.Region",
          action_name: :create,
          action_type: :create,
          metadata:
            AshBulkDurable.Sheet.Mapping.to_metadata(%AshBulkDurable.Sheet.Mapping{
              resource: Example.Test.Region,
              action: Ash.Resource.Info.action(Example.Test.Region, :create),
              columns: %{name: "name"}
            }),
          total_rows: 5,
          mode: :per_row,
          chunk_size: 2,
          rows:
            Enum.map(1..5, fn i ->
              name = "Region #{tag}#{i}"
              %{input: %{name: name}, metadata: %{"name" => name}}
            end)
        },
        overrides
      )

    Ash.create!(BulkAction, attrs, action: :create, authorize?: false)
  end

  defp set_oban_job_state(job_id, state) do
    {1, _} =
      Example.Repo.update_all(
        from(j in Oban.Job, where: j.id == ^job_id),
        set: [state: state]
      )

    :ok
  end

  # Drive the LV's form to a submittable state: pick Region/create and upload
  # the CSV so `uploaded_file` is populated and the fields auto-map.
  defp ready_to_submit(view) do
    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => "region"})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => "create"})

    file =
      file_input(view, "#main_form", :sheet, [
        %{name: "regions.csv", content: region_csv(), type: "text/csv"}
      ])

    render_upload(file, "regions.csv")
    view
  end

  # ── Submit ──────────────────────────────────────────────────────────────

  describe "submit happy path" do
    test "persists a queued bulk action, lands on ?bulk_action=<id>, and subscribes the LV", %{
      conn: conn,
      super_user: user
    } do
      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      view
      |> ready_to_submit()
      |> form("#main_form")
      |> render_submit()

      render_async(view, 2000)

      bulk_action = unresolved_bulk_action(user.id)
      assert bulk_action.status == :queued
      assert bulk_action.total_rows == 3
      assert bulk_action.mode == :per_row
      assert bulk_action.chunk_size == 50
      assert is_integer(bulk_action.oban_job_id)

      assert_patch(view, "/bulk?bulk_action=#{bulk_action.id}")
      assert render(view) =~ "bulk-action-panel"

      # Subscription proof: a terminal-state broadcast re-renders the panel.
      Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)
      html = render(view)
      assert html =~ "Completed"
      assert html =~ "Dismiss"
    end

    test "all_or_nothing stores the all-or-nothing mode", %{
      conn: conn,
      super_user: user
    } do
      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      view
      |> ready_to_submit()
      |> form("#main_form", %{"all_or_nothing" => "on"})
      |> render_submit()

      render_async(view, 2000)

      bulk_action = unresolved_bulk_action(user.id)
      assert bulk_action.mode == :all_or_nothing
      assert bulk_action.total_rows == 3
    end
  end

  describe "submit while a bulk action is already in flight" do
    test "surfaces the one-unresolved flash and resets to ready", %{conn: conn, super_user: user} do
      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      view |> ready_to_submit()

      # A competing bulk action appears (e.g. another tab) after this LV mounted, so
      # mount didn't attach it — the submit's create hits the partial unique
      # index.
      create_bulk_action!(user.id)

      view |> form("#main_form") |> render_submit()
      render_async(view, 2000)

      assert render(view) =~ "You have an unfinished bulk action."
      # Still on the form (no bulk action attached to this LV), ready to retry.
      refute render(view) =~ "bulk-action-panel"
    end

    test "a parked :completed_with_errors bulk action also blocks a new submit", %{
      conn: conn,
      super_user: user
    } do
      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      view |> ready_to_submit()

      # The competing bulk action finished with errors after this LV mounted: it is
      # terminal for the worker but still holds the one-unresolved slot.
      bulk_action = create_bulk_action!(user.id)

      Ash.update!(bulk_action, %{result: :completed_with_errors},
        action: :mark_finished,
        authorize?: false
      )

      view |> form("#main_form") |> render_submit()
      render_async(view, 2000)

      assert render(view) =~ "You have an unfinished bulk action."
    end
  end

  # ── Mount / reconnect ─────────────────────────────────────────────

  describe "mount with an in-flight bulk action" do
    test "reattaches, lands the URL on ?bulk_action=<id>, and tracks progress broadcasts", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)

      # The mount-time "land URL on ?bulk_action=<id>" patch happens during connect,
      # so it isn't `assert_patch`-visible (that's only post-connect events);
      # the post-connect ?bulk_action= landing is covered by the submit happy path.
      # Here we assert the bulk action is attached and tracked.
      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      assert render(view) =~ "bulk-action-panel"

      # The progress bar only renders once the worker has started (:running);
      # a :queued bulk action shows no counter. Both broadcasts reach the LV.
      running = Ash.update!(bulk_action, %{}, action: :mark_running, authorize?: false)
      Ash.update!(running, %{n: 3}, action: :bump_rows_done, authorize?: false)
      assert render(view) =~ "3 of 5 rows done"
    end
  end

  describe "mount with a parked :completed_with_errors bulk action" do
    test "reattaches to the errored bulk action instead of showing the empty form", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)
      # The worker finished legitimately — its Oban job is :completed — and
      # left failed rows behind. Closing the tab must not strand the bulk action.
      set_oban_job_state(bulk_action.oban_job_id, "completed")

      Ash.update!(bulk_action, %{result: :completed_with_errors},
        action: :mark_finished,
        authorize?: false
      )

      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      html = render(view)
      assert html =~ "bulk-action-panel"
      assert html =~ "Completed with errors"
      assert html =~ "Abandon failed rows"

      # The mount-time stuck bulk action rescue must NOT treat the parked bulk action as
      # worker-lost just because its job is terminal — the worker finished.
      assert reload(bulk_action).status == :completed_with_errors
    end
  end

  # ── Stuck bulk action rescue ─────────────────────────────────────────────

  describe "mount with a provably-dead worker" do
    test "flips a discarded-job bulk action to :failed and frees the slot", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)
      set_oban_job_state(bulk_action.oban_job_id, "discarded")

      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      assert reload(bulk_action).status == :failed
      html = render(view)
      assert html =~ "Failed"
      assert html =~ "Dismiss"

      # Dismissing a terminal bulk action returns the user to the empty form.
      view |> element("#bulk-action-panel button", "Dismiss") |> render_click()
      assert_patch(view, "/bulk")
      refute render(view) =~ "bulk-action-panel"

      # Slot is free: fetch_for_user_unresolved no longer finds a bulk action.
      assert is_nil(unresolved_bulk_action(user.id))
    end

    test "leaves a bulk action with a live (available) job untouched", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)
      # Freshly enqueued jobs are :available in Oban's manual testing mode —
      # the rescue must not touch them.
      {:ok, _view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      assert reload(bulk_action).status == :queued
    end
  end

  # ── Terminal-state actions ────────────────────────────────────────

  describe "abandon_failed_rows" do
    test "marks a :completed_with_errors bulk action :cancelled and returns to the form", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)

      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      Ash.update!(bulk_action, %{result: :completed_with_errors},
        action: :mark_finished,
        authorize?: false
      )

      html = render(view)
      assert html =~ "Completed with errors"
      assert html =~ "Abandon failed rows"

      # Abandon is destructive (rows + staged files are gone for good), so
      # the button must ask for confirmation first.
      abandon = view |> element("#bulk-action-panel button", "Abandon failed rows") |> render()
      assert abandon =~ "data-confirm"
      assert abandon =~ "permanently abandoned"

      view |> element("#bulk-action-panel button", "Abandon failed rows") |> render_click()

      assert_patch(view, "/bulk")
      assert reload(bulk_action).status == :cancelled
      refute render(view) =~ "bulk-action-panel"
    end
  end

  # `?bulk_action=<id>` is a meaningful deep-link. Bookmarking a finished
  # run and reopening the URL must reattach it read-only — the panel's
  # Dismiss / errors-sheet / "Start again" controls all key off the
  # attached terminal record. Cross-owner / unknown / malformed ids
  # strip the param, and an unresolved bulk action always wins so a stale
  # bookmark can't bypass the one-unresolved-per-user rule.
  describe "deep-link ?bulk_action=<id> for a terminal bulk action" do
    test "attaches a :completed bulk action owned by the user read-only", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)

      Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)

      {:ok, view, html} =
        conn |> login_as(user) |> live(~p"/bulk?bulk_action=#{bulk_action.id}")

      assert html =~ "bulk-action-panel"
      assert html =~ "Completed"
      assert html =~ "Dismiss"

      # Dismiss from a deep-linked terminal bulk action strips the param.
      view |> element("#bulk-action-panel button", "Dismiss") |> render_click()
      assert_patch(view, "/bulk")
      refute render(view) =~ "bulk-action-panel"
    end

    test "attaches a :failed bulk action owned by the user with the root-cause panel", %{
      conn: conn,
      super_user: user
    } do
      bulk_action = create_bulk_action!(user.id)

      Ash.update!(
        bulk_action,
        %{
          result:
            {:failed,
             %{
               reason: :atomic_chunk_rolled_back,
               error: "code: has already been taken",
               row_index: 2
             }}
        },
        action: :mark_finished,
        authorize?: false
      )

      {:ok, _view, html} =
        conn |> login_as(user) |> live(~p"/bulk?bulk_action=#{bulk_action.id}")

      assert html =~ "bulk-action-panel"
      assert html =~ "Row 3: code: has already been taken"
      refute html =~ "Abandon failed rows"
      assert html =~ "Start again with same settings"
    end

    # The mount-time strip patch is not `assert_patch`-visible (same
    # constraint as the existing "reattaches…" test at line ~203), so
    # these scenarios assert state via the absence of the bulk action panel.

    test "strips ?bulk_action=<id> for a bulk action owned by a different user", %{
      conn: conn,
      super_user: user
    } do
      stranger_id = Ecto.UUID.generate()
      bulk_action = create_bulk_action!(stranger_id)

      Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)

      {:ok, view, _html} =
        conn |> login_as(user) |> live(~p"/bulk?bulk_action=#{bulk_action.id}")

      refute render(view) =~ "bulk-action-panel"
    end

    test "strips ?bulk_action= for an unknown id", %{conn: conn, super_user: user} do
      {:ok, view, _html} =
        conn |> login_as(user) |> live(~p"/bulk?bulk_action=#{Ecto.UUID.generate()}")

      refute render(view) =~ "bulk-action-panel"
    end

    test "strips ?bulk_action= for a malformed id", %{conn: conn, super_user: user} do
      {:ok, view, _html} =
        conn |> login_as(user) |> live(~p"/bulk?bulk_action=not-a-uuid")

      refute render(view) =~ "bulk-action-panel"
    end

    # Nothing identity-derived paints before the socket connects: the tab's
    # impersonation token rides the connect params, and this page's resource
    # list is `Ash.can?`-filtered per actor, so the disconnected paint would be
    # the wrong user's. The app layout holds a loading state for both of these
    # until the connected mount — including the deep-link case that
    # `reconcile_run_param/2` already deferred.
    test "disconnected first paint of ?bulk_action=<id> renders neither the bulk action nor the form",
         %{conn: conn, super_user: user} do
      bulk_action = create_bulk_action!(user.id)
      Ash.update!(bulk_action, %{result: :completed}, action: :mark_finished, authorize?: false)

      conn = conn |> login_as(user) |> get(~p"/bulk?bulk_action=#{bulk_action.id}")
      body = html_response(conn, 200)

      assert body =~ "loading-spinner"
      refute body =~ ~s(id="main_form")
      refute body =~ "bulk-action-panel"
    end

    test "disconnected first paint of /bulk renders no form either", %{
      conn: conn,
      super_user: user
    } do
      conn = conn |> login_as(user) |> get(~p"/bulk")
      body = html_response(conn, 200)

      assert body =~ "loading-spinner"
      refute body =~ ~s(id="main_form")
    end

    test "the user's unresolved bulk action wins over a deep-link to a terminal one", %{
      conn: conn,
      super_user: user
    } do
      _unresolved = create_bulk_action!(user.id)

      terminal = create_bulk_action!(Ecto.UUID.generate())
      Ash.update!(terminal, %{result: :completed}, action: :mark_finished, authorize?: false)

      {:ok, view, _html} =
        conn |> login_as(user) |> live(~p"/bulk?bulk_action=#{terminal.id}")

      # Mount auto-attached the user's :queued unresolved bulk action, not the
      # terminal deep-link target. The panel shows the queued bulk action's
      # status, not "Completed".
      html = render(view)
      assert html =~ "bulk-action-panel"
      refute html =~ "Completed"
    end
  end

  describe "the buttons on a failed bulk action" do
    test "shows the captured root cause and 'Start again with same settings' prefills the form",
         %{conn: conn, super_user: user} do
      bulk_action = create_bulk_action!(user.id)

      {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")

      Ash.update!(
        bulk_action,
        %{
          result:
            {:failed,
             %{
               reason: :atomic_chunk_rolled_back,
               error: "code: has already been taken",
               row_index: 2
             }}
        },
        action: :mark_finished,
        authorize?: false
      )

      html = render(view)
      assert html =~ "rolled back"
      assert html =~ "Row 3: code: has already been taken"

      view
      |> element("#bulk-action-panel button", "Start again with same settings")
      |> render_click()

      # The patch lands back on the form with the bulk action's settings encoded in
      # the URL, ready for a fresh file upload.
      path = assert_patch(view)
      params = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert params["resource"] == "region"
      assert params["action"] == "create"
      assert params["mapping[name]"] == "name"

      html = render(view)
      refute html =~ "bulk-action-panel"
      # The mapping panel is back with the bulk action's field selection re-applied.
      assert html =~ "field__name"
    end
  end
end
