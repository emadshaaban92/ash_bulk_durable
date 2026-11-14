defmodule ExampleWeb.Bulk.Components.ProgressPanelTest do
  @moduledoc """
  Step 7 (#39) coverage for `ExampleWeb.Bulk.Components.ProgressPanel`. The
  component pattern-matches on the bulk action's plain fields (`status`,
  `rows_done`, `total_rows`, `mode`, `result`), so these render tests
  pass lightweight maps rather than building real `BulkAction` rows.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ExampleWeb.Bulk.Components.ProgressPanel
  alias Phoenix.LiveView.AsyncResult

  defp bulk_action(overrides) do
    Map.merge(
      %{
        id: "run-abc",
        status: :running,
        rows_done: 0,
        total_rows: 10,
        mode: :per_row,
        result: nil
      },
      overrides
    )
  end

  defp render_panel(bulk_action, uploads \\ %{}, errors_sheet \\ nil, retry_filename \\ nil) do
    render_component(&ProgressPanel.progress_panel/1,
      bulk_action: bulk_action,
      uploads: uploads,
      errors_sheet: errors_sheet,
      retry_filename: retry_filename
    )
  end

  defp cwe_bulk_action,
    do: bulk_action(%{status: :completed_with_errors, rows_done: 8, total_rows: 10})

  test "nil bulk action renders nothing" do
    assert render_component(&ProgressPanel.progress_panel/1, bulk_action: nil, uploads: %{}) == ""
  end

  describe ":queued" do
    test "shows a Queued badge, no progress bar, no actions" do
      html = render_panel(bulk_action(%{status: :queued}))

      assert html =~ "Queued"
      refute html =~ "<progress"
      refute html =~ "Dismiss"
      refute html =~ "Abandon failed rows"
    end
  end

  describe "a progress hint" do
    defp render_with_progress(bulk_action, progress) do
      render_component(&ProgressPanel.progress_panel/1,
        bulk_action: bulk_action,
        progress: progress,
        uploads: %{}
      )
    end

    test "phase 1's shows the references resolved, in either mode" do
      progress = %{phase: :resolving, committed: true, rows_resolved: 4, rows_to_resolve: 9}

      for mode <- [:per_row, :all_or_nothing] do
        html = render_with_progress(bulk_action(%{mode: mode}), progress)
        assert html =~ "Resolving references: 4 of 9"
      end
    end

    test "an all-or-nothing write's says nothing is saved yet" do
      progress = %{phase: :writing, committed: false, rows_processed: 300, total_rows: 1000}
      html = render_with_progress(bulk_action(%{mode: :all_or_nothing}), progress)

      assert html =~ "300 of 1000 processed, not saved until the run finishes"
      assert html =~ "Running as a single all-or-nothing transaction"
    end

    test "shows nothing once the bulk action isn't running" do
      progress = %{phase: :writing, committed: false, rows_processed: 3, total_rows: 10}
      html = render_with_progress(bulk_action(%{status: :completed, rows_done: 10}), progress)

      refute html =~ "bulk-action-progress-hint"
    end

    test "no hint, no line" do
      refute render_with_progress(bulk_action(%{}), nil) =~ "bulk-action-progress-hint"
    end
  end

  describe ":running" do
    test "a per-row bulk action shows a progress bar and the rows_done / total_rows counter" do
      html = render_panel(bulk_action(%{status: :running, rows_done: 3, total_rows: 10}))

      assert html =~ "<progress"
      assert html =~ "progress-primary"
      assert html =~ "3 of 10 rows done"
      refute html =~ "Dismiss"
    end

    test "an all-or-nothing bulk action shows a Running… badge and NO progress bar" do
      html =
        render_panel(
          bulk_action(%{status: :running, rows_done: 0, total_rows: 10, mode: :all_or_nothing})
        )

      assert html =~ "Running…"
      refute html =~ "<progress"
      refute html =~ "Dismiss"
    end
  end

  describe ":completed_with_errors" do
    test "shows all three controls wired to the right events" do
      html = render_panel(cwe_bulk_action())

      # Download errors sheet — opens the on-demand S3 generation modal (no
      # app-side controller/route). No modal until the button is clicked.
      assert html =~ "Download errors sheet"
      assert html =~ ~s(phx-click="prepare_errors_sheet")
      refute html =~ "modal-open"

      # Upload corrections to retry — the re-upload form's validate hook.
      assert html =~ "Upload corrections to retry"
      assert html =~ ~s(phx-change="validate_retry_upload")

      # Abandon failed rows — flips the bulk action to :cancelled.
      assert html =~ "Abandon failed rows"
      assert html =~ ~s(phx-click="abandon_failed_rows")

      # No Dismiss in this state — the user is meant to retry or abandon.
      refute html =~ ">Dismiss<"

      # "Abandon bulk action" is the :failed panel's.
      refute html =~ "Abandon bulk action"
    end

    test "renders the retry live_file_input once a :retry_csv upload is allocated" do
      html = render_panel(cwe_bulk_action(), allocate_retry_upload())
      assert html =~ ~s(type="file")
    end

    test "Retry failed rows button is disabled until a corrections file is staged" do
      # No file staged yet: the button renders but is disabled and the
      # explicit submit_retry event is wired up.
      html = render_panel(cwe_bulk_action(), allocate_retry_upload())
      assert html =~ "Retry failed rows"
      assert html =~ ~s(phx-click="submit_retry")
      assert html =~ ~r/<button[^>]*phx-click="submit_retry"[^>]*disabled/

      # Once the host LV stashes parsed rows (signalled via retry_filename),
      # the filename is shown and the button is enabled.
      ready = render_panel(cwe_bulk_action(), allocate_retry_upload(), nil, "corrections.csv")
      assert ready =~ "corrections.csv"
      refute ready =~ ~r/<button[^>]*phx-click="submit_retry"[^>]*disabled/
    end
  end

  describe "failed-row preview" do
    defp preview_rows do
      [
        %{
          row_index: 4,
          cells: %{"code" => "001", "name" => "Cairo"},
          error: "code: has already been taken"
        }
      ]
    end

    test "shows the cells and clean error of previewed failed rows" do
      html =
        render_component(&ProgressPanel.progress_panel/1,
          bulk_action: cwe_bulk_action(),
          uploads: %{},
          errors_sheet: nil,
          failed_preview: preview_rows()
        )

      assert html =~ "<table"
      assert html =~ "code: has already been taken"
      assert html =~ "Cairo"
      assert html =~ "001"
    end

    test "notes how many more failed rows are in the sheet" do
      # cwe_bulk_action has 2 failed rows (10 total, 8 done) but we preview only 1.
      html =
        render_component(&ProgressPanel.progress_panel/1,
          bulk_action: cwe_bulk_action(),
          uploads: %{},
          errors_sheet: nil,
          failed_preview: preview_rows()
        )

      assert html =~ "Showing 1 of 2 failed rows"
    end

    test "renders no preview table when there are no previewed rows" do
      refute render_panel(cwe_bulk_action()) =~ "<table"
    end
  end

  describe "errors-sheet modal" do
    test "spins while the sheet is generating" do
      html = render_panel(cwe_bulk_action(), %{}, AsyncResult.loading())

      assert html =~ "modal-open"
      assert html =~ "loading-spinner"
      assert html =~ "Preparing errors sheet…"
    end

    test "shows a Download link to the presigned URL once ready" do
      url = "https://s3.example.com/bulk-staging/u/run-abc/errors_sheet.csv?sig=x"
      html = render_panel(cwe_bulk_action(), %{}, AsyncResult.ok(%{url: url}))

      assert html =~ "modal-open"
      assert html =~ ~s(href="#{url}")
      assert html =~ "Your errors sheet is ready."
    end

    test "offers Retry when generation failed" do
      failed = AsyncResult.failed(AsyncResult.loading(), {:error, :boom})
      html = render_panel(cwe_bulk_action(), %{}, failed)

      assert html =~ "Couldn&#39;t prepare the errors sheet."
      assert html =~ "Retry"
    end

    test "the modal exposes a close control" do
      html = render_panel(cwe_bulk_action(), %{}, AsyncResult.loading())
      assert html =~ ~s(phx-click="close_errors_sheet")
    end
  end

  describe "terminal states with nothing to retry show only Dismiss" do
    for status <- [:completed, :cancelled] do
      test "#{status}" do
        html = render_panel(bulk_action(%{status: unquote(status), rows_done: 10, result: %{}}))

        assert html =~ "Dismiss"
        assert html =~ ~s(phx-click="dismiss_bulk_action")
        refute html =~ "Abandon failed rows"
        refute html =~ "Download errors sheet"
      end
    end

    test ":failed can be corrected and retried, or abandoned whole" do
      html = render_panel(bulk_action(%{status: :failed, mode: :all_or_nothing, result: %{}}))

      assert html =~ ~s(phx-click="dismiss_bulk_action")
      assert html =~ "Download errors sheet"
      assert html =~ "Upload corrections to retry"
      assert html =~ "to run the whole bulk action again"
      refute html =~ "Abandon failed rows"

      assert html =~ "Abandon bulk action"
      assert html =~ ~s(phx-click="abandon_failed_rows")
      assert html =~ "This bulk action will be permanently abandoned"
    end

    test ":failed renders reason-derived copy" do
      html =
        render_panel(
          bulk_action(%{status: :failed, result: %{"reason" => "atomic_phase1_failed"}})
        )

      assert html =~ "stopped before any rows were written"
      assert html =~ "alert-error"
    end

    test ":failed with a reason it doesn't know says only that it failed" do
      html = render_panel(bulk_action(%{status: :failed, result: %{"reason" => "worker_lost"}}))

      assert html =~ "The bulk action failed."
      refute html =~ "stopped before finishing"
      assert html =~ "alert-error"
    end

    test ":failed as crashed says it kept stopping" do
      html =
        render_panel(
          bulk_action(%{status: :failed, mode: :all_or_nothing, result: %{"reason" => "crashed"}})
        )

      assert html =~ "kept stopping before it could finish"
      assert html =~ "No rows were saved"
      assert html =~ "alert-error"
    end

    test ":failed as crashed per row says it never reached a row, and keeps what it saved" do
      html = render_panel(bulk_action(%{status: :failed, result: %{"reason" => "crashed"}}))

      assert html =~ "kept stopping before it reached a row"
      assert html =~ "Rows already saved stay saved"
      refute html =~ "No rows were saved"
    end
  end

  # A real %Phoenix.LiveView.UploadConfig{} only exists inside a live view,
  # so allocate one on a bare socket and lift out the uploads map.
  defp allocate_retry_upload do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.LiveView.allow_upload(:retry_csv, accept: ~w(.csv .xlsx), max_entries: 1)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:uploads)
  end
end
