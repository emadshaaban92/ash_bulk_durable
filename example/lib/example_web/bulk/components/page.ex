defmodule ExampleWeb.Bulk.Components.Page do
  @moduledoc """
  Top-level Phoenix component that renders the entire Bulk Actions page —
  header form (resource / action / identity / file picker), the field
  mapping grid, the data preview table and the instructional/empty states.

  The `ExampleWeb.Bulk.LiveView` macro injects a default `render/1` that
  delegates here. Consumers can override `render/1` if they need a
  different layout.

  All helpers used by the template (`rows_with_errors/2`, `cell_preview/3`,
  `companion_uploads_in_progress?/2`, the private `select/1` component)
  are colocated in this module — the template, the data shaping, and the
  small UI building blocks share the same file.
  """
  use Phoenix.Component
  use Gettext, backend: ExampleWeb.Gettext

  alias ExampleWeb.Bulk.Components.FieldMappingPanel
  alias ExampleWeb.Bulk.ErrorMessage
  alias ExampleWeb.Bulk.Components.ProgressPanel
  alias ExampleWeb.Bulk.Utils
  alias ExampleWeb.Bulk.ViewOptions

  attr :options, :any, required: true
  attr :uploaded_file, :any, default: nil
  attr :csv_keys, :list, required: true
  attr :uploads, :any, required: true
  attr :errors, :list, default: []
  attr :companion_upload_names, :any, required: true
  attr :bulk_action, :any, default: nil
  attr :bulk_action_status, :atom, default: :ready
  attr :errors_sheet, :any, default: nil
  attr :failed_preview, :list, default: []
  attr :uncommitted_rows, :integer, default: nil
  attr :retry_filename, :string, default: nil
  attr :params, :map, default: %{}

  def bulk_page(assigns) do
    ~H"""
    <%= cond do %>
      <% not Phoenix.LiveView.connected?(@socket) -> %>
        <%!--
          The list of what the reader may run is asked of their policies once
          the socket connects, so the first paint holds neither form nor panel.
        --%>
        <div class="flex items-center justify-center p-12 text-base-content/60">
          <span class="loading loading-spinner loading-sm me-2" /> {gettext("Loading bulk action…")}
        </div>
      <% @bulk_action -> %>
        <ProgressPanel.progress_panel
          bulk_action={@bulk_action}
          uploads={@uploads}
          errors_sheet={@errors_sheet}
          failed_preview={@failed_preview}
          uncommitted_rows={@uncommitted_rows}
          retry_filename={@retry_filename}
        />
      <% @params["bulk_action"] -> %>
        <%!--
          Disconnected-paint placeholder for a `?bulk_action=<id>` deep link.
          `reconcile_run_param/2` only fetches the bulk action once the LV connects, so
          without this branch the disconnected first paint would flash the
          empty submit form before the progress panel renders.
        --%>
        <div class="flex items-center justify-center p-12 text-base-content/60">
          <span class="loading loading-spinner loading-sm me-2" /> {gettext("Loading bulk action…")}
        </div>
      <% true -> %>
        <div class="p-3 sm:p-5">
          <.form
            id="main_form"
            for={%{}}
            phx-change="update_main_form"
            phx-submit="submit_main_form"
            class="w-full space-y-4 lg:space-y-0 lg:grid lg:grid-cols-5 lg:gap-6"
          >
            <div class="w-full">
              <.select
                name="resource_name"
                label={gettext("Resource")}
                phx-change="update_resource"
                value={@options |> ViewOptions.resource_name()}
                options={@options |> ViewOptions.resources_select_opts()}
              />
            </div>

            <div class="w-full">
              <.select
                name="action_name"
                label={gettext("Action")}
                disabled={is_nil(@options.resource)}
                phx-change="update_action"
                value={@options |> ViewOptions.action_name()}
                options={@options |> ViewOptions.actions_select_opts()}
              />
            </div>

            <div class="w-full">
              <.select
                name="identity_name"
                label={gettext("Lookup by")}
                disabled={is_nil(@options.action) or @options.action.type == :create}
                phx-change="update_identity"
                value={@options |> ViewOptions.identity_name()}
                options={@options |> ViewOptions.identities_select_opts()}
              />
            </div>
            <div class="w-full">
              <label class="label" for={@uploads.sheet.ref}>{gettext("File")}</label>
              <div
                :if={not is_nil(@uploaded_file)}
                class="flex items-center gap-2 h-10 px-3 rounded-lg border border-base-300 bg-base-100"
              >
                <span class="text-success">✓</span>
                <span class="truncate flex-1 text-sm" title={@uploaded_file.name}>
                  {@uploaded_file.name}
                </span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs btn-circle"
                  phx-click="clear_upload"
                  aria-label={gettext("Clear file")}
                  title={gettext("Clear file")}
                >
                  ✕
                </button>
              </div>
              <.live_file_input
                :if={is_nil(@uploaded_file) && ViewOptions.upload_ready?(@options)}
                upload={@uploads.sheet}
                class="file-input w-full"
              />
            </div>
            <div class="w-full flex flex-col justify-end gap-1">
              <label
                :if={not is_nil(@uploaded_file)}
                class="label cursor-pointer justify-start gap-2"
                title={atomic_mode_tooltip(@uploaded_file)}
              >
                <input
                  type="checkbox"
                  name="all_or_nothing"
                  class="checkbox checkbox-sm"
                  disabled={atomic_mode_disabled?(@uploaded_file)}
                />
                <span class="label-text text-xs">{gettext("Apply all rows or none")}</span>
              </label>
              <p :if={not is_nil(@uploaded_file)} class="text-xs opacity-60 -mt-1 ps-7">
                {gettext("If any row fails, nothing is changed.")}
              </p>
              <button
                type="submit"
                class="btn btn-primary btn-block"
                disabled={
                  not ViewOptions.upload_ready?(@options) or is_nil(@uploaded_file) or
                    companion_uploads_in_progress?(@uploads, @companion_upload_names)
                }
              >
                {gettext("Submit")}
              </button>
            </div>
          </.form>
        </div>

        <section class="p-3 sm:p-5">
          <div class="mx-auto w-full">
            <div class="card bg-base-100 shadow-md border border-base-300">
              <!-- Placeholder reserving the table's space until resource/action are picked -->
              <div
                :if={not ViewOptions.upload_ready?(@options)}
                class="flex items-center justify-center min-h-[4.5rem] bg-base-200/50 border-b border-base-300 px-4 text-center"
              >
                <p class="text-sm text-base-content/50">
                  {gettext(
                    "Select a resource and action above to preview the fields you'll need to provide."
                  )}
                </p>
              </div>

              <!-- Field mapping panel -->
              <div :if={ViewOptions.upload_ready?(@options)}>
                <FieldMappingPanel.field_mapping_panel
                  options={@options}
                  csv_keys={@csv_keys}
                  uploaded_file={@uploaded_file}
                  uploads={@uploads}
                />
              </div>

              <!-- Data preview table -->
              <div
                :if={ViewOptions.upload_ready?(@options)}
                class="overflow-x-auto border-t border-base-300"
              >
                <table class="w-full text-sm text-start">
                  <thead class="text-xs uppercase bg-base-200 text-base-content/70">
                    <tr>
                      <th
                        :if={@errors != []}
                        class="px-2 py-3 w-16 sticky start-0 bg-base-200"
                      />
                      <th
                        :for={bf <- ViewOptions.fields(@options)}
                        scope="col"
                        class="px-3 py-3 min-w-[160px] font-medium"
                      >
                        {Utils.field_label(bf.field.name, bf.resource)}
                      </th>
                    </tr>
                  </thead>

                  <tbody :if={not is_nil(@uploaded_file)} id={@uploaded_file.uuid}>
                    <tr
                      :for={{row, errors} <- rows_with_errors(@uploaded_file.sheet.rows, @errors)}
                      class="border-b border-base-300"
                    >
                      <td :if={@errors != []} class="px-2 py-3 sticky start-0 bg-base-100">
                        <div class="max-w-[120px]">
                          <p
                            :for={error <- errors}
                            class="text-error text-xs truncate"
                            title={error_text(error)}
                          >
                            {error_text(error)}
                          </p>
                        </div>
                      </td>
                      <td :for={bf <- ViewOptions.fields(@options)} class="px-3 py-3">
                        <div class="max-w-[180px]">
                          <% preview = cell_preview(row, @options, bf.field.name) %>
                          <span class="text-xs lg:text-sm block truncate" title={preview}>
                            {preview}
                          </span>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <!-- Upload instructions, visible until a file is uploaded for the current configuration -->
              <div
                :if={is_nil(@uploaded_file) or not ViewOptions.upload_ready?(@options)}
                class="card-body text-center"
              >
                <div class="py-8">
                  <svg
                    class="mx-auto h-12 w-12 text-base-content/40"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"
                    />
                  </svg>
                  <h3 class="mt-4 text-lg font-medium">
                    {gettext("Bulk Action Instructions")}
                  </h3>
                  <div class="mt-4 text-start max-w-2xl mx-auto space-y-4">
                    <div class="bg-info/10 border border-info/30 rounded-lg p-4">
                      <h4 class="text-sm font-semibold mb-2">
                        {gettext("How to run a bulk action:")}
                      </h4>
                      <ol class="text-sm text-base-content/70 space-y-2 list-decimal list-inside">
                        <li>
                          <strong>{gettext("Select Resource:")}</strong> {gettext(
                            "Choose the type of data to act on"
                          )}
                        </li>
                        <li>
                          <strong>{gettext("Select Action:")}</strong>
                          {gettext("Choose what to do with the data (Create, Update, Activate, etc.)")}
                        </li>
                        <li>
                          <strong>{gettext("Choose Lookup By:")}</strong>
                          {gettext(
                            "For updates, select which field to look up existing records by (Name, Code, etc.)"
                          )}
                        </li>
                        <li>
                          <strong>{gettext("Upload Data:")}</strong>
                          {gettext("Select your CSV or Excel file containing the data")}
                        </li>
                        <li>
                          <strong>{gettext("Map Fields:")}</strong> {gettext(
                            "Match your file columns to the system fields"
                          )}
                        </li>
                        <li>
                          <strong>{gettext("Preview & Submit:")}</strong> {gettext(
                            "Review the data preview and click Submit"
                          )}
                        </li>
                      </ol>
                    </div>
                    <div class="bg-base-200 border border-base-300 rounded-lg p-4">
                      <h4 class="text-sm font-semibold mb-2">
                        {gettext("Data Requirements:")}
                      </h4>
                      <ul class="text-sm text-base-content/70 space-y-1 list-disc list-inside">
                        <li>{gettext("Supported formats: CSV, Excel (.xlsx)")}</li>
                        <li>{gettext("First row should contain column headers")}</li>
                        <li>{gettext("Maximum file size: 30MB")}</li>
                        <li>{gettext("Ensure data matches the selected resource type")}</li>
                      </ul>
                    </div>
                  </div>
                  <p :if={is_nil(@options.resource)} class="mt-4 text-sm text-base-content/50">
                    {gettext(
                      "Start by selecting a resource and action above, then upload your file to begin."
                    )}
                  </p>
                  <p
                    :if={@options.resource && is_nil(@options.action)}
                    class="mt-4 text-sm text-base-content/50"
                  >
                    {gettext("Select an action above to continue.")}
                  </p>
                  <p
                    :if={
                      @options.resource && @options.action && @options.action.type != :create &&
                        is_nil(@options.identity)
                    }
                    class="mt-4 text-sm text-base-content/50"
                  >
                    {gettext("Select a lookup field above to identify existing records.")}
                  </p>
                </div>
              </div>

              <!-- Data summary -->
              <div
                :if={
                  ViewOptions.upload_ready?(@options) and not is_nil(@uploaded_file) and
                    @uploaded_file.sheet.rows != []
                }
                class="px-4 py-3 border-t border-base-300 bg-base-300/30"
              >
                <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
                  <div class="text-sm text-base-content/60">
                    <strong>{gettext("File:")}</strong> {@uploaded_file.name} • {ngettext(
                      "%{count} row uploaded",
                      "%{count} rows uploaded",
                      length(@uploaded_file.sheet.rows)
                    )}
                  </div>
                  <div class="text-sm">
                    <%= if @errors != [] do %>
                      <div class="badge badge-error gap-1">
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          viewBox="0 0 24 24"
                          fill="currentColor"
                          class="w-3 h-3"
                        >
                          <path
                            fill-rule="evenodd"
                            d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12ZM12 8.25a.75.75 0 0 1 .75.75v3.75a.75.75 0 0 1-1.5 0V9a.75.75 0 0 1 .75-.75Zm0 8.25a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Z"
                            clip-rule="evenodd"
                          />
                        </svg>
                        {ngettext("%{count} error found", "%{count} errors found", length(@errors))}
                      </div>
                    <% else %>
                      <div class="badge badge-success gap-1">
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          viewBox="0 0 24 24"
                          fill="currentColor"
                          class="w-3 h-3"
                        >
                          <path
                            fill-rule="evenodd"
                            d="M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm13.36-1.814a.75.75 0 1 0-1.22-.872l-3.236 4.53L9.53 12.22a.75.75 0 0 0-1.06 1.06l2.25 2.25a.75.75 0 0 0 1.14-.094l3.75-5.25Z"
                            clip-rule="evenodd"
                          />
                        </svg>
                        {gettext("Ready to submit")}
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
    <% end %>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :name, :string
  attr :options, :list, default: [{nil, ""}]
  attr :value, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled required)

  defp select(assigns) do
    ~H"""
    <div class="w-full">
      <label :if={@label && @label != ""} class="label" for={@id || @name}>{@label}</label>
      <span :if={@rest[:required]} class="text-error"> &ast;</span>
      <select
        id={@id || @name}
        name={@name}
        class={[
          "select select-sm w-full",
          @class
        ]}
        {@rest}
      >
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
    </div>
    """
  end

  defp rows_with_errors(rows, []) do
    rows |> Stream.map(&{&1, []}) |> Stream.take(200)
  end

  defp rows_with_errors(rows, errors) do
    rows
    |> Stream.with_index()
    |> Stream.map(fn {row, index} ->
      {row, errors |> Enum.filter(&(&1.path == [index]))}
    end)
    |> Stream.filter(&(elem(&1, 1) != []))
  end

  # Worded as a stored row's is, so the preview and the bulk action read alike.
  defp error_text(error), do: ErrorMessage.display_error(error)

  # Body-cell preview for a field's mapped value(s) on a given CSV row.
  # Composite mappings join their sub-values with " | " so the user can
  # eyeball each identity key's contribution.
  defp cell_preview(row, options, field_atom) do
    case ViewOptions.mapping_value(options, field_atom) do
      nil ->
        ""

      %{} = sub_map ->
        sub_map
        |> Enum.map_join(" | ", fn {_sub_key, csv_col} ->
          to_string(Map.get(row, csv_col, ""))
        end)

      csv_col ->
        Map.get(row, csv_col, "")
    end
  end

  # True if any companion slot has an entry that hasn't finished uploading.
  # Drives the Submit button's `disabled` state so the user can't click
  # through to the raise.
  defp companion_uploads_in_progress?(uploads, names) do
    Enum.any?(names, fn name ->
      case Map.get(uploads, name) do
        nil -> false
        %{entries: entries} -> Enum.any?(entries, &(not &1.done?))
      end
    end)
  end

  # ── Submit-form helpers ───────────────────────────────────────────────

  # "Apply all rows or none" picks atomic mode (one transaction). Disabled past
  # the configured row cap so a long-running transaction can't be requested
  # by accident; the action validates the same limit defensively.
  defp atomic_mode_disabled?(nil), do: false

  defp atomic_mode_disabled?(%{sheet: %{rows: rows}}),
    do: length(rows) > AshBulkDurable.config(:atomic_mode_max_rows, 10_000)

  defp atomic_mode_tooltip(uploaded_file) do
    if atomic_mode_disabled?(uploaded_file) do
      max = AshBulkDurable.config(:atomic_mode_max_rows, 10_000)

      gettext(
        "Atomic mode is unavailable for bulk actions over %{max} rows — larger ones run in best-effort mode.",
        max: max
      )
    end
  end
end
