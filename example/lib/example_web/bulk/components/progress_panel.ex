defmodule ExampleWeb.Bulk.Components.ProgressPanel do
  @moduledoc """
  Live progress / terminal-state view for an attached `BulkAction`.
  `ExampleWeb.Bulk.Components.Page` renders this in place of the
  submit form whenever a bulk action is attached. The row carries everything the
  panel needs (`status`, `rows_done`, `total_rows`, `mode`,
  `result`), so a single component renders every state — there is no
  per-message switch on the LV side.

  ## Render branches (mode-aware progress)

    * `:queued` — "Queued" badge, no progress bar, no actions.
    * `:running` + `:per_row` — a chunked progress bar and a
      `rows_done / total_rows` counter. No actions.
    * `:running` + `:all_or_nothing` — a "Running…" badge only. No
      progress bar: all-or-nothing keeps `rows_done` at `0`
      until the single commit, so a bar could only show 0% or snap to
      100% — worse than nothing.
    * `:running`, either mode, with a `progress` hint (the worker's
      `"progress"` broadcast, `AshBulkDurable.Core.Progress`) — a line
      under the above: "Resolving references: n of m" in phase 1, or "n of
      m processed, not saved until the run finishes" for an all-or-nothing
      write. The host LV keeps only a hint for the bulk action's current
      pass, and drops it when the bulk action's status, pass or `rows_done`
      changes.
    * `:completed` / `:failed` / `:cancelled` — terminal badge + a
      "Dismiss" button (`phx-click="dismiss_bulk_action"`). A `:failed` bulk action
      additionally renders the captured root cause (first offending row +
      humanized error, when the worker recorded one), the retry controls
      below bar the abandon button, and a "Start again with same settings"
      button (`phx-click="retry_same_settings"`) that lands the user back on
      the form with the bulk action's resource / action / mapping pre-selected.
    * `:completed_with_errors` — parked until retried or abandoned:
      a prominent "Retry with corrections" zone (file picker + an
      explicit "Retry failed rows" button that fires once the host LV has
      stashed the parsed sheet on the socket as `:retry_sheet`), plus two
      secondary controls in the action row: "Download errors sheet"
      (opens a modal that generates the CSV on demand and serves it
      from storage via a presigned URL) and "Abandon failed rows"
      (`phx-click="abandon_failed_rows"`, behind a `data-confirm`
      spelling out that the rows and their uploaded files are gone for
      good).

  The re-upload `live_file_input` only renders once the host LV has
  allocated a `:retry_csv` upload (passed in via `uploads`); the
  "Retry failed rows" button is enabled once the host signals a file is
  parsed and staged (via `retry_filename`). The errors-sheet modal's
  async state is threaded in via `errors_sheet` (the `%AsyncResult{}`
  from `assign_async`).
  """
  use Phoenix.Component
  use Gettext, backend: ExampleWeb.Gettext

  attr :bulk_action, :any, required: true
  attr :progress, :map, default: nil
  attr :uploads, :any, default: %{}
  attr :errors_sheet, :any, default: nil
  attr :failed_preview, :list, default: []
  attr :retry_filename, :string, default: nil

  def progress_panel(%{bulk_action: nil} = assigns), do: ~H""

  def progress_panel(assigns) do
    assigns = assign(assigns, :retry_upload, Map.get(assigns.uploads, :retry_csv))

    ~H"""
    <div id="bulk-action-panel" class="p-3 sm:p-5">
      <div class="card bg-base-100 shadow-md border border-base-300">
        <div class="card-body gap-6">
          <div class="flex items-center justify-between gap-2">
            <h2 class="card-title">{gettext("Bulk action")}</h2>
            <span class={["badge", badge_class(@bulk_action)]}>{status_label(@bulk_action)}</span>
          </div>

          <%= cond do %>
            <% per_row_running?(@bulk_action) -> %>
              <div>
                <progress
                  class="progress progress-primary w-full"
                  value={@bulk_action.rows_done}
                  max={@bulk_action.total_rows}
                ></progress>
                <p class="text-sm text-base-content/60 mt-1">
                  {rows_done_label(@bulk_action)}
                </p>
              </div>
            <% @bulk_action.status == :running -> %>
              <p class="text-sm text-base-content/60">
                {gettext("Running as a single all-or-nothing transaction…")}
              </p>
            <% @bulk_action.status == :queued -> %>
              <p class="text-sm text-base-content/60">{gettext("Waiting to start…")}</p>
            <% @bulk_action.status == :failed -> %>
              <div role="alert" class="alert alert-error">
                <div>
                  <p>{failure_message(@bulk_action.result)}</p>
                  <p :if={failure_detail(@bulk_action)} class="text-sm opacity-80">
                    {failure_detail(@bulk_action)}
                  </p>
                </div>
              </div>
            <% @bulk_action.status == :completed_with_errors -> %>
              <div role="alert" class="alert alert-warning">
                <span>
                  {gettext(
                    "%{done} of %{total} rows done. %{failed} need attention — fix them in the errors sheet and re-upload to retry.",
                    done: @bulk_action.rows_done,
                    total: @bulk_action.total_rows,
                    failed: failed_count(@bulk_action)
                  )}
                </span>
              </div>
            <% true -> %>
              <p class="text-sm text-base-content/60">
                {rows_done_label(@bulk_action)}
              </p>
          <% end %>

          <p
            :if={progress_label(@bulk_action, @progress)}
            id="bulk-action-progress-hint"
            class="text-sm text-base-content/60"
          >
            {progress_label(@bulk_action, @progress)}
          </p>

          <.failed_rows_preview
            :if={@bulk_action.status == :completed_with_errors and @failed_preview != []}
            rows={@failed_preview}
            total_failed={failed_count(@bulk_action)}
          />

          <.retry_zone
            :if={retryable?(@bulk_action)}
            mode={@bulk_action.mode}
            retry_upload={@retry_upload}
            retry_filename={@retry_filename}
          />

          <div class="card-actions justify-end items-center gap-2">
            <.errors_secondary_actions :if={retryable?(@bulk_action)} bulk_action={@bulk_action} />
            <button
              :if={@bulk_action.status == :failed}
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="retry_same_settings"
            >
              {gettext("Start again with same settings")}
            </button>
            <button
              :if={@bulk_action.status in [:completed, :failed, :cancelled]}
              type="button"
              class="btn btn-sm"
              phx-click="dismiss_bulk_action"
            >
              {gettext("Dismiss")}
            </button>
          </div>
        </div>
      </div>
      <.errors_sheet_modal :if={@errors_sheet} async={@errors_sheet} />
    </div>
    """
  end

  # Errors-sheet download modal. A single "Download errors sheet"
  # click opens it; it spins while the CSV is built + uploaded to storage, then
  # shows a Download link to the presigned URL.
  # `async` is the `%Phoenix.LiveView.AsyncResult{}` from `assign_async`.
  attr :async, :any, required: true

  defp errors_sheet_modal(assigns) do
    ~H"""
    <dialog class="modal modal-open">
      <div class="modal-box">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-lg font-semibold">{gettext("Errors sheet")}</h3>
          <button
            type="button"
            phx-click="close_errors_sheet"
            class="btn btn-sm btn-circle btn-ghost"
            aria-label={gettext("Close")}
          >
            ✕
          </button>
        </div>
        <div class="flex flex-col items-center justify-center py-8">
          <div :if={@async.loading} class="flex flex-col items-center gap-3">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <span class="text-base-content/70">{gettext("Preparing errors sheet…")}</span>
          </div>

          <div :if={@async.ok? && @async.result} class="flex flex-col items-center gap-4">
            <p class="text-success font-medium">{gettext("Your errors sheet is ready.")}</p>
            <a href={@async.result.url} target="_blank" class="btn btn-primary">
              {gettext("Download")}
            </a>
          </div>

          <div :if={@async.failed} class="flex flex-col items-center gap-4">
            <p class="text-error">{gettext("Couldn't prepare the errors sheet.")}</p>
            <button type="button" phx-click="prepare_errors_sheet" class="btn btn-primary">
              {gettext("Retry")}
            </button>
          </div>
        </div>
      </div>
      <div class="modal-backdrop">
        <button type="button" phx-click="close_errors_sheet">{gettext("close")}</button>
      </div>
    </dialog>
    """
  end

  # Primary action zone for `:completed_with_errors`. The file picker
  # auto-uploads + parses the corrected CSV; the user then clicks "Retry
  # failed rows" to actually re-run, which keeps the two steps (commit to a
  # specific file vs. commit to running it) reversible.
  attr :mode, :atom, required: true
  attr :retry_upload, :any, default: nil
  attr :retry_filename, :string, default: nil

  defp retry_zone(assigns) do
    ~H"""
    <div
      id="retry-zone"
      class="rounded-lg border border-base-300 bg-base-200/40 p-4 sm:p-5"
    >
      <div class="flex flex-col gap-1 mb-3">
        <p class="font-medium">{gettext("Retry with corrections")}</p>
        <p class="text-sm text-base-content/70">
          {retry_instructions(@mode)}
        </p>
      </div>

      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <.form
          for={%{}}
          phx-change="validate_retry_upload"
          id="retry-upload-form"
          class="flex items-center gap-2 flex-wrap"
        >
          <label class="text-sm text-base-content/80">{gettext("Upload corrections to retry")}</label>
          <.live_file_input
            :if={@retry_upload}
            upload={@retry_upload}
            class="file-input file-input-sm"
          />
          <span :if={@retry_filename} class="text-sm text-base-content/70 truncate max-w-[14rem]">
            {@retry_filename}
          </span>
        </.form>

        <button
          type="button"
          class="btn btn-sm btn-primary self-end sm:self-auto"
          phx-click="submit_retry"
          disabled={is_nil(@retry_filename)}
        >
          {gettext("Retry failed rows")}
        </button>
      </div>
    </div>
    """
  end

  defp retry_instructions(:all_or_nothing) do
    gettext(
      "Upload your fixed CSV and click Retry failed rows to run the whole bulk action again."
    )
  end

  defp retry_instructions(_per_row) do
    gettext(
      "Upload your fixed CSV and click Retry failed rows to run only the failed rows again."
    )
  end

  # Secondary controls for a retryable bulk action. "Download
  # errors sheet" opens the modal (`errors_sheet_modal/1`), which generates
  # the CSV on demand and serves it from storage via a presigned download.
  attr :bulk_action, :any, required: true

  defp errors_secondary_actions(assigns) do
    ~H"""
    <button type="button" class="btn btn-sm" phx-click="prepare_errors_sheet">
      {gettext("Download errors sheet")}
    </button>
    <button
      :if={@bulk_action.status == :completed_with_errors}
      type="button"
      class="btn btn-sm btn-error btn-soft"
      phx-click="abandon_failed_rows"
      data-confirm={abandon_confirmation(@bulk_action)}
    >
      {gettext("Abandon failed rows")}
    </button>
    """
  end

  defp abandon_confirmation(bulk_action) do
    ngettext(
      "%{count} failed row will be permanently abandoned and the uploaded files deleted. Download the errors sheet first if you might run it again later — it can be uploaded as a new bulk action.",
      "%{count} failed rows will be permanently abandoned and the uploaded files deleted. Download the errors sheet first if you might run them again later — it can be uploaded as a new bulk action.",
      failed_count(bulk_action)
    )
  end

  defp rows_done_label(bulk_action),
    do:
      gettext("%{done} of %{total} rows done",
        done: bulk_action.rows_done,
        total: bulk_action.total_rows
      )

  # The worker's hint while nothing it commits shows here: phase 1's rows
  # (committed, but the bulk action isn't updated), or an all-or-nothing
  # write's rows (not committed at all yet).
  defp progress_label(%{status: :running}, %{phase: :resolving} = progress),
    do:
      gettext("Resolving references: %{done} of %{total}",
        done: progress.rows_resolved,
        total: progress.rows_to_resolve
      )

  defp progress_label(%{status: :running}, %{phase: :writing} = progress),
    do:
      gettext("%{done} of %{total} processed, not saved until the run finishes",
        done: progress.rows_processed,
        total: progress.total_rows
      )

  defp progress_label(_bulk_action, _progress), do: nil

  # A few failed rows inline — the cells of the errors sheet that hold
  # something plus a clean error, so they can see what to fix before
  # downloading the full sheet.
  attr :rows, :list, required: true
  attr :total_failed, :integer, required: true

  defp failed_rows_preview(assigns) do
    assigns = assign(assigns, :columns, preview_columns(assigns.rows))

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-xs">
        <thead>
          <tr>
            <th>{gettext("Row")}</th>
            <th>{gettext("Error")}</th>
            <th :for={col <- @columns}>{col}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td class="font-mono">{row.row_index + 1}</td>
            <td class="text-error">{row.error}</td>
            <td :for={col <- @columns}>{Map.get(row.cells, col, "")}</td>
          </tr>
        </tbody>
      </table>
      <p :if={@total_failed > length(@rows)} class="text-xs text-base-content/60 mt-1">
        {gettext(
          "Showing %{shown} of %{total} failed rows — download the errors sheet for the rest.",
          shown: length(@rows),
          total: @total_failed
        )}
      </p>
    </div>
    """
  end

  defp preview_columns(rows) do
    rows |> Enum.flat_map(&Map.keys(&1.cells)) |> Enum.uniq() |> Enum.sort()
  end

  # ── State → presentation ──────────────────────────────────────────────

  # Per-row bulk actions are the only ones with honest mid-run progress to
  # render. `:queued` ones haven't started, so no bar; all-or-nothing ones
  # jump 0 → total at commit, so no bar.
  defp retryable?(%{status: status}), do: status in [:completed_with_errors, :failed]

  defp per_row_running?(%{status: :running, mode: :per_row}), do: true
  defp per_row_running?(_bulk_action), do: false

  defp status_label(%{status: :running} = bulk_action) do
    if per_row_running?(bulk_action), do: gettext("Running"), else: gettext("Running…")
  end

  defp status_label(%{status: :completed_with_errors}), do: gettext("Completed with errors")
  defp status_label(%{status: status}), do: ExampleWeb.Bulk.Utils.humanize(status)

  defp badge_class(%{status: :completed}), do: "badge-success"
  defp badge_class(%{status: :completed_with_errors}), do: "badge-warning"
  defp badge_class(%{status: :failed}), do: "badge-error"
  defp badge_class(%{status: :cancelled}), do: "badge-ghost"
  defp badge_class(%{status: :queued}), do: "badge-ghost"
  defp badge_class(_run), do: "badge-info"

  # Every callsite renders for `:completed_with_errors`, where each row has
  # either succeeded (bumping `rows_done`) or landed `:failed` — no rows
  # remain in `:pending` / `:resolved`. The subtraction is therefore exact
  # in that state; do not use it for `:running` bulk actions where in-flight rows
  # would inflate the count.
  defp failed_count(%{total_rows: total_rows, rows_done: rows_done}), do: total_rows - rows_done

  # Reason-derived copy for a `:failed` bulk action. `result` is JSONB, so its keys
  # are strings (`ApplyMarkFinished` stringifies the `{:failed, %{reason:}}`
  # detail map). `{:failed, term}` bulk actions have no `"reason"` → generic copy.
  defp failure_message(%{} = result) do
    case result["reason"] do
      "atomic_chunk_rolled_back" ->
        gettext(
          "A row failed, so the whole bulk action was rolled back (\"Apply all rows or none\" was on)."
        )

      "atomic_phase1_failed" ->
        gettext("A row failed, so the bulk action stopped before any rows were written.")

      "staged_file_download_error" ->
        gettext("A companion file couldn't be downloaded from storage.")

      "crashed" ->
        gettext(
          "The bulk action kept stopping before it could finish, so it was not run again. No rows were saved (\"Apply all rows or none\" was on)."
        )

      "unreadable" ->
        gettext("What this bulk action held no longer exists, so it can't run.")

      "gone" ->
        gettext("The action this bulk action runs no longer exists, so it can't run.")

      "resolver_prepare_error" ->
        gettext("The bulk action couldn't be prepared. Please check your data and try again.")

      _ ->
        gettext("The bulk action failed.")
    end
  end

  defp failure_message(_), do: gettext("The bulk action failed.")

  # Second line of the `:failed` alert: the first offending row (1-based,
  # matching the failed-rows preview) and its humanized error, when the
  # worker captured them (atomic-mode failures).
  defp failure_detail(%{result: %{} = result} = bulk_action) do
    case {result["row_index"], ExampleWeb.Bulk.ErrorMessage.display(Map.get(bulk_action, :error))} do
      {_row_index, message} when not is_binary(message) or message == "" ->
        nil

      {row_index, message} when is_integer(row_index) ->
        gettext("Row %{row}: %{message}", row: row_index + 1, message: message)

      {_row_index, message} ->
        message
    end
  end

  defp failure_detail(_bulk_action), do: nil
end
