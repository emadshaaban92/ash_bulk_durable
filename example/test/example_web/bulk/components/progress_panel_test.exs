defmodule ExampleWeb.Bulk.Components.ProgressPanelTest do
  @moduledoc """
  Step 7 (#39) coverage for `ExampleWeb.Bulk.Components.ProgressPanel`. The
  component pattern-matches on the bulk action's plain fields (`status`,
  `rows_done`, `rows_pending`, `total_rows`, `mode`, `started_at`,
  `result`), so these render tests
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
        rows_pending: 0,
        started_at: nil,
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

  defp render_running_all_or_nothing(overrides, uncommitted_rows) do
    render_component(&ProgressPanel.progress_panel/1,
      bulk_action: bulk_action(Map.merge(%{status: :running, mode: :all_or_nothing}, overrides)),
      uploads: %{},
      uncommitted_rows: uncommitted_rows
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

    test "an all-or-nothing bulk action resolving shows how many rows are resolved" do
      html = render_running_all_or_nothing(%{rows_pending: 4}, nil)
      assert html =~ "Resolving references: 6 of 10 rows"
    end

    test "an all-or-nothing bulk action writing says since when, and the unsaved hint" do
      started_at = DateTime.add(DateTime.utc_now(), -180, :second)
      html = render_running_all_or_nothing(%{started_at: started_at}, 300)

      assert html =~ "Writing all 10 rows in one transaction, started 3 min ago"
      assert html =~ "300 of 10 rows processed, not saved yet."
    end

    test "with no hint, an all-or-nothing bulk action shows only its phase" do
      html = render_running_all_or_nothing(%{}, nil)
      assert html =~ "Writing all 10 rows in one transaction"
      refute html =~ "not saved yet"
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

    test ":failed can be corrected and retried, but not abandoned" do
      html = render_panel(bulk_action(%{status: :failed, mode: :all_or_nothing, result: %{}}))

      assert html =~ ~s(phx-click="dismiss_bulk_action")
      assert html =~ "Download errors sheet"
      assert html =~ "Upload corrections to retry"
      assert html =~ "to run the whole bulk action again"
      refute html =~ "Abandon failed rows"
    end

    test ":failed renders reason-derived copy" do
      html = render_panel(bulk_action(%{status: :failed, result: %{"reason" => "worker_lost"}}))

      assert html =~ "stopped before finishing"
      assert html =~ "under Retry with corrections"
      assert html =~ "alert-error"
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
