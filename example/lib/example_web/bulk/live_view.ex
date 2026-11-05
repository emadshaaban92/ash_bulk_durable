defmodule ExampleWeb.Bulk.LiveView do
  @moduledoc """
  Base module for the Bulk Actions LiveView.

  Provides all mount/handle_params/handle_event logic. Consumer modules
  supply two callbacks that wire the framework into the host application:

      defmodule MyAppWeb.BulkLive.Index do
        use ExampleWeb.Bulk.LiveView

        @impl ExampleWeb.Bulk.LiveView
        def scope(socket), do: socket.assigns.scope

        @impl ExampleWeb.Bulk.LiveView
        def bulk_path, do: "/bulk"
      end

  The `__using__` macro is intentionally tiny — it injects `use Phoenix.LiveView`,
  the behaviour declaration, and a handful of one-line delegates that hand off
  to the real implementations in this module. The consumer module records
  itself in `socket.assigns.__bulk_module__` at mount time so helpers
  can resolve the configured `scope/1` and `bulk_path/0` callbacks without
  threading the module through every function.

  All entry points are `defoverridable` so consumers can wrap or replace any
  callback when they need to customize behaviour.

  ## Durable bulk actions

  Submitting a bulk action never runs the row loop inline.
  Instead the LV persists an `BulkAction` (config `:bulk_action_resource`)
  via `start_async/3`, `:queued`, for `AshBulkDurable.Core.Poller` to claim
  and run. The LV then subscribes to the bulk action's PubSub topic and
  reads the bulk action again whenever the worker commits rows or it changes
  state, so `rows_done` (its succeeded rows, counted) moves as rows commit.
  An all-or-nothing run also says how many rows its open transaction has
  processed, a hint kept only while the page is open. On mount, a logged-in
  user with an unresolved bulk action — `:queued`, `:running`, or parked in
  `:completed_with_errors` — is reattached to it. A run whose node died is
  resumed by another node once its lease runs out, so there is nothing to
  rescue here. An errored
  bulk action must be retried to completion or abandoned before a new bulk action can
  start. Creates, updates and destroys all run this way.
  """

  use Gettext, backend: ExampleWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [
      allow_upload: 3,
      assign_async: 3,
      cancel_upload: 3,
      connected?: 1,
      consume_uploaded_entries: 3,
      consume_uploaded_entry: 3,
      disallow_upload: 2,
      push_patch: 2,
      put_flash: 3,
      start_async: 3
    ]

  alias AshBulkDurable.Core.Owner
  alias AshBulkDurable.Sheet.{ErrorsSheet, Mapping}
  alias ExampleWeb.Bulk.ViewOptions

  require Ash.Query

  # How many failed rows the panel previews inline; the rest live in the
  # downloadable errors sheet.
  @failed_preview_limit 5

  @callback scope(Phoenix.LiveView.Socket.t()) :: term()
  @callback bulk_path() :: String.t()

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView

      @behaviour ExampleWeb.Bulk.LiveView

      @impl true
      def render(assigns), do: ExampleWeb.Bulk.Components.Page.bulk_page(assigns)

      @impl true
      def mount(params, session, socket),
        do: ExampleWeb.Bulk.LiveView.on_mount(params, session, socket, __MODULE__)

      @impl true
      def handle_params(params, url, socket),
        do: ExampleWeb.Bulk.LiveView.on_handle_params(params, url, socket)

      @impl true
      def handle_event(event, params, socket),
        do: ExampleWeb.Bulk.LiveView.on_handle_event(event, params, socket)

      @impl true
      def handle_async(name, result, socket),
        do: ExampleWeb.Bulk.LiveView.on_handle_async(name, result, socket)

      @impl true
      def handle_info(msg, socket),
        do: ExampleWeb.Bulk.LiveView.on_handle_info(msg, socket)

      defoverridable render: 1,
                     mount: 3,
                     handle_params: 3,
                     handle_event: 3,
                     handle_async: 3,
                     handle_info: 2
    end
  end

  @doc false
  def on_mount(_params, _session, socket, module) do
    socket =
      socket
      |> assign(:__bulk_module__, module)
      |> allow_upload(:sheet,
        accept: ~w(.csv .xlsx),
        max_entries: 1,
        max_file_size: 30 * 1024 * 1024,
        auto_upload: true,
        progress: &__MODULE__.on_progress/3
      )
      # Errors-sheet retry upload. Auto-uploads on file-pick so
      # the progress callback can parse the corrected CSV and stash the
      # sheet on the socket; the actual `AshBulkDurable.retry/3`
      # call waits for an explicit "Retry failed rows" click, so a
      # user who picks the wrong file can re-pick or back out without
      # committing the retry.
      |> allow_upload(:retry_csv,
        accept: ~w(.csv .xlsx),
        max_entries: 1,
        max_file_size: 30 * 1024 * 1024,
        auto_upload: true,
        progress: &__MODULE__.on_retry_progress/3
      )
      |> assign_allowed_resources()
      |> assign(uploaded_file: nil)
      |> assign(retry_sheet: nil, retry_filename: nil)
      |> assign_csv_keys()
      |> assign(errors: [])
      |> assign(
        bulk_action_status: :ready,
        bulk_action: nil,
        uncommitted_rows: nil,
        errors_sheet: nil,
        failed_preview: []
      )
      |> maybe_attach_unresolved_bulk_action()

    {:ok, socket}
  end

  @doc false
  def on_handle_params(params, url, socket) do
    case reconcile_run_param(socket, params) do
      {:redirect, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        path = URI.parse(url).path

        options =
          ViewOptions.from_url_params(params, scope(socket), socket.assigns.allowed_resources)

        socket =
          socket
          |> assign(:page_title, gettext("Bulk Actions"))
          |> assign(:path, path |> String.split("?") |> List.first())
          |> assign(:params, params)
          |> assign(:options, options)
          |> sync_companion_uploads()

        {:noreply, socket}
    end
  end

  @doc false
  def on_handle_event("update_main_form", _params, socket), do: {:noreply, socket}

  # Validate hook for the errors-sheet re-upload form. The file
  # itself is auto-uploaded + parsed in `on_retry_progress/3`; this hook
  # just keeps the form responsive on file pick.
  def on_handle_event("validate_retry_upload", _params, socket), do: {:noreply, socket}

  # Explicit "Retry failed rows" click. The corrected CSV has already
  # been auto-uploaded and parsed into `retry_sheet` by `on_retry_progress/3`;
  # this handler is where the user opts in to re-running the failed rows.
  # Decoupling apply from upload lets the user re-pick a different file (or
  # back out entirely) before committing the retry.
  def on_handle_event("submit_retry", _params, socket) do
    case {socket.assigns[:bulk_action], socket.assigns[:retry_sheet]} do
      {%{} = bulk_action, %AshBulkDurable.Sheet{} = sheet} ->
        {:noreply,
         socket
         |> apply_retry(bulk_action, sheet)
         |> assign(retry_sheet: nil, retry_filename: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def on_handle_event(
        "submit_main_form",
        _params,
        %{assigns: %{bulk_action_status: :persisting}} = socket
      ) do
    # Double-click guard. The DB partial unique index would also
    # catch a duplicate insert, but there's no reason to reach the DB twice.
    {:noreply, socket}
  end

  def on_handle_event("submit_main_form", params, socket) do
    {:noreply, submit(socket, params, socket.assigns.options.action)}
  end

  # Navigation-only dismiss for a terminal bulk action: drop the assign and
  # patch back to the bare `/bulk`. The bulk action is already terminal, so the
  # one-in-flight slot is free and there's no status mutation to do.
  def on_handle_event("dismiss_bulk_action", _params, socket) do
    {:noreply,
     socket
     |> assign(:bulk_action, nil)
     |> assign(:failed_preview, [])
     |> push_patch(to: bulk_path(socket))}
  end

  # "Start again with same settings" on a `:failed` bulk action: drop the
  # terminal bulk action and land back on the submit form with the bulk action's persisted
  # resource / action / identity / mapping pre-selected — the user only
  # re-uploads the files. `:failed` is terminal, so the one-unresolved slot
  # is already free and no status mutation is needed.
  def on_handle_event("retry_same_settings", _params, socket) do
    case socket.assigns.bulk_action do
      %{status: :failed} = bulk_action ->
        params = bulk_action_settings_params(bulk_action)

        {:noreply,
         socket
         |> assign(:bulk_action, nil)
         |> assign(:failed_preview, [])
         |> push_patch(
           to: "#{bulk_path(socket)}?#{URI.encode_query(params)}" |> String.trim_trailing("?")
         )}

      _other ->
        {:noreply, socket}
    end
  end

  # Abandon the still-`:failed` rows of a `:completed_with_errors` bulk action.
  # Marks the bulk action `:cancelled` (whose after_action eagerly purges
  # staging) then patches home.
  def on_handle_event("abandon_failed_rows", _params, socket) do
    socket =
      case socket.assigns.bulk_action do
        nil ->
          socket

        bulk_action ->
          {:ok, _abandoned} = AshBulkDurable.abandon(bulk_action, scope: scope(socket))
          socket |> assign(:bulk_action, nil) |> assign(:failed_preview, [])
      end

    {:noreply, push_patch(socket, to: bulk_path(socket))}
  end

  # Errors-sheet download. Opens a modal that spins while the CSV is
  # built + uploaded to storage off the LV process, then shows a presigned-URL
  # download link — a browser→storage presigned-download pattern, so no app-side
  # controller/route. `assign_async` drives the modal's loading/ok/failed
  # states.
  def on_handle_event("prepare_errors_sheet", _params, socket) do
    case socket.assigns[:bulk_action] do
      nil ->
        {:noreply, socket}

      %{id: bulk_action_id} ->
        # Capture only the id — re-fetch inside the async fn so the sheet is
        # built against the bulk action's current state, not a possibly-stale snapshot
        # closed over from the click. (A pubsub-driven `:bulk_action` swap
        # between click and execution would otherwise be invisible here.)
        bulk_action_resource = AshBulkDurable.config(:bulk_action_resource)
        # The sheet words each error in the reader's language, and a task
        # inherits no locale.
        locale = Gettext.get_locale(ExampleWeb.Gettext)

        {:noreply,
         assign_async(socket, :errors_sheet, fn ->
           Gettext.put_locale(locale)

           with {:ok, fresh_bulk_action} <-
                  Ash.get(bulk_action_resource, bulk_action_id, authorize?: false),
                {:ok, url} <- ExampleWeb.Bulk.ErrorsSheet.generate_url(fresh_bulk_action) do
             {:ok, %{errors_sheet: %{url: url}}}
           else
             {:error, reason} -> {:error, reason}
           end
         end)}
    end
  end

  # Close the errors-sheet modal. Drops the async assign so the modal
  # disappears; the next "Download errors sheet" click re-generates.
  def on_handle_event("close_errors_sheet", _params, socket) do
    {:noreply, assign(socket, :errors_sheet, nil)}
  end

  def on_handle_event("clear_upload", _params, socket) do
    {:noreply, reset_upload(socket)}
  end

  def on_handle_event("update_resource", %{"resource_name" => resource_name}, socket) do
    options = ViewOptions.set_resource(socket.assigns.options, resource_name)
    {:noreply, push_options(socket, options)}
  end

  def on_handle_event("update_action", %{"action_name" => action_name}, socket) do
    options = ViewOptions.set_action(socket.assigns.options, action_name)
    {:noreply, push_options(socket, options)}
  end

  def on_handle_event("update_identity", %{"identity_name" => identity_name}, socket) do
    options = ViewOptions.set_identity(socket.assigns.options, identity_name)
    {:noreply, push_options(socket, options)}
  end

  def on_handle_event("update_mapping", %{"_target" => ["mapping__" <> path]} = params, socket) do
    csv_key = params["mapping__" <> path]

    options =
      case String.split(path, "__", parts: 2) do
        [field, sub_key] ->
          # Composite-key identity: select name is `mapping__<field>__<sub_key>`,
          # tracked as a nested map under `mapping[field][sub_key]`.
          ViewOptions.update_mapping(socket.assigns.options, field, sub_key, csv_key)

        [field] ->
          ViewOptions.update_mapping(socket.assigns.options, field, csv_key)
      end

    {:noreply, push_options(socket, options)}
  end

  def on_handle_event(
        "update_rel_identities",
        %{"_target" => ["rel_identities__" <> field]} = params,
        socket
      ) do
    options =
      ViewOptions.update_rel_identities(
        socket.assigns.options,
        field,
        params["rel_identities__" <> field]
      )

    {:noreply, push_options(socket, options)}
  end

  @doc false
  # Result of the durable bulk action insert started by `start_persist/6`.
  # The async function returns the raw `Ash.create/3` tuple, so the outer
  # `{:ok, ...}` is the task's success and the inner is the create result.
  def on_handle_async(:persist, {:ok, {:ok, bulk_action}}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_action_status, :ready)
     |> attach_bulk_action(bulk_action)
     |> push_patch(to: "#{bulk_path(socket)}?bulk_action=#{bulk_action.id}")}
  end

  def on_handle_async(:persist, {:ok, {:error, %Ash.Error.Invalid{} = err}}, socket) do
    socket = assign(socket, :bulk_action_status, :ready)

    message =
      if unresolved_run_violation?(err) do
        gettext(
          "You have an unfinished bulk action. Finish, retry, or abandon it before starting another."
        )
      else
        gettext("Failed to start the bulk action.")
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  def on_handle_async(:persist, {:ok, {:error, _other}}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_action_status, :ready)
     |> put_flash(:error, gettext("Failed to start the bulk action."))}
  end

  def on_handle_async(:persist, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_action_status, :ready)
     |> put_flash(:error, gettext("Failed to start the bulk action."))}
  end

  def on_handle_async(_name, _result, socket), do: {:noreply, socket}

  @doc false
  # Two kinds of message arrive on the bulk action's topic through the host
  # endpoint, each a `%Phoenix.Socket.Broadcast{}`: `Ash.Notifier.PubSub`
  # (configured on `BulkAction`) wraps each update of the bulk action, and the
  # worker's `"progress"` (`AshBulkDurable.Core.Progress`) says rows were
  # committed, or how far an all-or-nothing transaction has got. Either way the
  # bulk action is read again, its rows counted — but only while we still
  # hold a matching bulk action, so a stray message can't re-show a panel the
  # user just dismissed.
  def on_handle_info(
        %Phoenix.Socket.Broadcast{payload: %Ash.Notifier.Notification{data: %{id: id}}},
        socket
      ),
      do: {:noreply, refresh_bulk_action(socket, id)}

  def on_handle_info(
        %Phoenix.Socket.Broadcast{
          event: "progress",
          payload: %{bulk_action_id: id, committed: false, rows_processed: processed} = hint
        },
        socket
      ) do
    if attached?(socket, id) and current_run?(socket, hint),
      do: {:noreply, assign(socket, :uncommitted_rows, processed)},
      else: {:noreply, socket}
  end

  def on_handle_info(
        %Phoenix.Socket.Broadcast{event: "progress", payload: %{bulk_action_id: id}},
        socket
      ),
      do: {:noreply, refresh_bulk_action(socket, id)}

  def on_handle_info(_msg, socket), do: {:noreply, socket}

  @doc false
  def on_progress(:sheet, entry, socket) do
    if entry.done? do
      uploaded_file =
        consume_uploaded_entry(socket, entry, fn %{} = meta ->
          {:ok,
           %{
             name: entry.client_name,
             uuid: entry.uuid,
             size: entry.client_size,
             path: meta.path,
             sheet: read_sheet!(meta.path, entry)
           }}
        end)

      socket =
        socket
        |> assign(uploaded_file: uploaded_file)
        |> assign_csv_keys()
        |> auto_fill_field_mappings()

      {:noreply, push_options(socket, socket.assigns.options)}
    else
      {:noreply, socket}
    end
  end

  @doc false
  # Errors-sheet retry. Parses the corrected CSV as soon as it
  # finishes uploading, stashes the parsed sheet on the socket as
  # `:retry_sheet`, and waits for the user to click "Retry failed rows"
  # (handled by `on_handle_event("submit_retry", ...)`). Decoupling parse
  # from apply means the user can re-pick a file or back out before the
  # retry actually fires.
  def on_retry_progress(:retry_csv, entry, socket) do
    if entry.done? and socket.assigns[:bulk_action] do
      sheet =
        consume_uploaded_entry(socket, entry, fn %{} = meta ->
          {:ok, read_sheet!(meta.path, entry)}
        end)

      {:noreply, assign(socket, retry_sheet: sheet, retry_filename: entry.client_name)}
    else
      {:noreply, socket}
    end
  end

  defp apply_retry(socket, bulk_action, sheet) do
    case AshBulkDurable.retry(bulk_action, sheet, scope: scope(socket)) do
      {:ok, retried} ->
        put_flash(
          socket,
          :info,
          ngettext(
            "Reopened %{count} row for retry.",
            "Reopened %{count} rows for retry.",
            retried.total_rows - Ash.load!(retried, :rows_done, authorize?: false).rows_done
          )
        )

      {:error, :gone} ->
        put_flash(
          socket,
          :error,
          gettext(
            "What this bulk action ran no longer exists, so it can't be retried. Abandon its failed rows to start a new one."
          )
        )

      {:error, %{unmatched: unmatched}} ->
        count = length(unmatched)

        put_flash(
          socket,
          :error,
          ngettext(
            "%{count} row didn't match the original bulk action. No rows were changed.",
            "%{count} rows didn't match the original bulk action. No rows were changed.",
            count
          )
        )

      {:error, _other} ->
        put_flash(socket, :error, gettext("Couldn't apply the corrections. Please try again."))
    end
  end

  # Resolve the consumer module's callbacks via the value stashed at mount.
  defp module(socket), do: socket.assigns.__bulk_module__

  # A record-less `Ash.can?` per resource and per action, and only the scope
  # moves the result — a tenant switch or impersonation navigates the browser
  # instead of patching this socket.
  defp assign_allowed_resources(socket) do
    assign(socket, :allowed_resources, ViewOptions.allowed_resources(scope(socket)))
  end

  defp scope(socket), do: module(socket).scope(socket)
  defp bulk_path(socket), do: module(socket).bulk_path()

  # ── Durable-run submit ──────────────────────────────────────────

  defp submit(socket, params, %{type: type}) when type in [:create, :update, :destroy] do
    submit_bulk_action(socket, params)
  end

  defp submit(socket, _params, _action), do: socket

  defp submit_bulk_action(socket, params) do
    %{options: options, uploaded_file: uploaded_file} = socket.assigns
    # Only fields the user actually mapped to a CSV column participate — an
    # unmapped field is skipped at apply-time anyway, so there's no reason to
    # insist on its companion upload (e.g. creating categories without images).
    fields = options |> ViewOptions.fields() |> mapped_fields(options.mapping)

    case validate_required_companions(socket, fields) do
      {:in_progress, names} ->
        put_flash(
          socket,
          :error,
          gettext(
            "Still uploading: %{names}. Please wait for the upload to finish before submitting.",
            names: join_names(names)
          )
        )

      {:missing, missing} ->
        put_flash(
          socket,
          :error,
          gettext("Missing required file uploads: %{names}", names: join_names(missing))
        )

      :ok ->
        start_persist(socket, options, uploaded_file, fields, params)
    end
  end

  # Stage the durable bulk action off the LV process: the sheet layer maps
  # every row to its target and input, then one transaction wraps the bulk
  # action insert + its rows, so a `:queued` bulk action always has every
  # row to run.
  defp start_persist(socket, options, uploaded_file, fields, params) do
    %{resource: resource, action: action} = options

    opts =
      [
        scope: scope(socket),
        mode: mode_for(params),
        # Companion bytes already live in staging; the consume callback's
        # `meta` is what `presign_companion/2` returned, so the key is
        # `meta.key`. The worker downloads them when the bulk action executes.
        companions: consume_companion_keys(socket, fields)
      ] ++ ViewOptions.sheet_options(options)

    socket
    |> assign(bulk_action_status: :persisting, errors: [])
    |> start_async(:persist, fn ->
      start_bulk_action(action.type, uploaded_file.sheet, resource, action.name, opts)
    end)
  end

  defp start_bulk_action(:create, sheet, resource, action, opts),
    do: AshBulkDurable.bulk_create(sheet, resource, action, opts)

  defp start_bulk_action(:update, sheet, resource, action, opts),
    do: AshBulkDurable.update_many(sheet, resource, action, opts)

  defp start_bulk_action(:destroy, sheet, resource, action, opts),
    do: AshBulkDurable.destroy_many(sheet, resource, action, opts)

  defp mode_for(%{"all_or_nothing" => "on"}), do: :all_or_nothing
  defp mode_for(_params), do: :per_row

  defp join_names(names), do: Enum.map_join(names, ", ", &to_string/1)

  # ── Unresolved bulk action reconnect + stuck bulk action rescue ──────────

  # Reattaches whatever bulk action holds the user's one-unresolved slot: a live
  # `:queued`/`:running` bulk action resumes its progress panel, and a parked
  # `:completed_with_errors` bulk action lands the user back on the errors-sheet /
  # retry / abandon controls — closing the tab never strands an errored
  # bulk action.
  defp maybe_attach_unresolved_bulk_action(socket) do
    with true <- connected?(socket),
         bulk_action when not is_nil(bulk_action) <- fetch_unresolved_bulk_action(socket) do
      attach_bulk_action(socket, bulk_action)
    else
      _ -> socket
    end
  end

  defp fetch_unresolved_bulk_action(socket) do
    case AshBulkDurable.config(:bulk_action_resource) do
      nil ->
        nil

      bulk_action_resource ->
        bulk_action_resource
        |> Ash.Query.for_read(:fetch_for_user_unresolved, %{
          user_id: Owner.worker_key(scope(socket))
        })
        |> Ash.read_one!(authorize?: false)
    end
  end

  # A hint from a run that lost its claim, still going on another node, would
  # make the count jump about: only the claim the page knows is shown. Every
  # claim resets `started_at`, which the page learns from the claim's own
  # `"progress"` broadcast.
  defp current_run?(socket, %{started_at: started_at}),
    do: socket.assigns.bulk_action.started_at == started_at

  defp current_run?(_socket, _hint), do: true

  defp attached?(socket, id) do
    case socket.assigns[:bulk_action] do
      %{id: ^id} -> true
      _other -> false
    end
  end

  # Reads the attached bulk action again, so its row counts are the committed
  # ones. The uncommitted hint only lives while the same run still runs: every
  # claim resets `started_at`, so a run another node took over starts afresh.
  defp refresh_bulk_action(socket, id) do
    with true <- attached?(socket, id),
         resource when not is_nil(resource) <- AshBulkDurable.config(:bulk_action_resource),
         {:ok, fresh} <-
           Ash.get(resource, id, authorize?: false, load: [:rows_done, :rows_pending]) do
      same_run? =
        fresh.status == :running and fresh.started_at == socket.assigns.bulk_action.started_at

      socket
      |> assign(:bulk_action, fresh)
      |> assign(:failed_preview, failed_preview(fresh))
      |> assign(:uncommitted_rows, if(same_run?, do: socket.assigns[:uncommitted_rows]))
    else
      _ -> socket
    end
  end

  # The panel shows the counts, which a bulk action read elsewhere doesn't load.
  defp with_counts(bulk_action),
    do: Ash.load!(bulk_action, [:rows_done, :rows_pending], authorize?: false)

  defp attach_bulk_action(socket, bulk_action) do
    subscribe_to_bulk_action(bulk_action)
    # A freshly-attached bulk action starts with the errors-sheet modal closed — any
    # async result held for a previous bulk action is stale. The retry stash is
    # cleared too: a different bulk action shouldn't carry a previously-staged file.
    socket
    |> assign(:bulk_action, with_counts(bulk_action))
    |> assign(:uncommitted_rows, nil)
    |> assign(:errors_sheet, nil)
    |> assign(:failed_preview, failed_preview(bulk_action))
    |> assign(:retry_sheet, nil)
    |> assign(:retry_filename, nil)
  end

  # Up to `@failed_preview_limit` failed rows (their cells + a clean error)
  # so the panel can show the user what to fix without downloading the sheet.
  # Only `:completed_with_errors` bulk actions have failed rows worth a query; every
  # other status short-circuits to `[]`, so the per-broadcast best-effort
  # progress updates never hit the DB here.
  defp failed_preview(%{status: :completed_with_errors} = bulk_action) do
    case AshBulkDurable.config(:row_resource) do
      nil ->
        []

      row_resource ->
        row_resource
        |> Ash.Query.filter(bulk_action_id == ^bulk_action.id and status == :failed)
        |> Ash.Query.sort(row_index: :asc)
        |> Ash.Query.limit(@failed_preview_limit)
        |> Ash.read!(authorize?: false)
        |> Enum.map(fn row ->
          %{
            row_index: row.row_index,
            cells: ErrorsSheet.cells(bulk_action, row),
            error: ExampleWeb.Bulk.ErrorMessage.display(row.error)
          }
        end)
    end
  rescue
    # A resource or action gone since it was parked must not lock its owner
    # out of the page they abandon it from.
    _stale_bulk_action -> []
  end

  defp failed_preview(_run), do: []

  defp subscribe_to_bulk_action(bulk_action) do
    case AshBulkDurable.config(:pubsub_module) do
      nil -> :ok
      mod -> mod.subscribe("bulk_action:#{bulk_action.id}")
    end
  end

  # Keep the `?bulk_action=<id>` URL param and the attached bulk action in lockstep.
  # A bookmarked or shared deep-link to a user's *own* terminal
  # bulk action is honored — it loads the bulk action read-only so the panel can render
  # the captured result, errors-sheet download, retry, etc. Mount's
  # auto-attach via `:fetch_for_user_unresolved` always wins when present,
  # so the deep-link path is only consulted when the user currently has
  # no unresolved bulk action. All branches terminate: a redirect re-enters
  # `handle_params` exactly once with the corrected param.
  defp reconcile_run_param(socket, params) do
    bulk_action = socket.assigns[:bulk_action]
    param_id = params["bulk_action"]

    cond do
      # URL already points at the attached bulk action — nothing to do.
      bulk_action && param_id == bulk_action.id ->
        {:ok, socket}

      # A bulk action is attached but the URL lost/mismatched it — land back on it.
      bulk_action ->
        {:redirect, push_patch(socket, to: "#{bulk_path(socket)}?bulk_action=#{bulk_action.id}")}

      # No attached bulk action + URL carries an id: defer the lookup until the
      # LV connects (so subscribe_to_bulk_action/1 lands on the live process and
      # we don't waste a DB read on the disconnected first paint).
      not is_nil(param_id) and connected?(socket) ->
        case fetch_run_owned_by_user(socket, param_id) do
          nil -> {:redirect, push_patch(socket, to: bulk_path(socket))}
          owned_bulk_action -> {:ok, attach_bulk_action(socket, owned_bulk_action)}
        end

      true ->
        {:ok, socket}
    end
  end

  # Looks up a bulk action by id, gated on `worker_key/1` so a user can only
  # deep-link to bulk actions they own. Returns nil for any failure
  # (missing config, malformed UUID, not found, owned by someone else)
  # — `reconcile_run_param/2` turns that into a strip-and-redirect.
  defp fetch_run_owned_by_user(socket, bulk_action_id) do
    case AshBulkDurable.config(:bulk_action_resource) do
      nil ->
        nil

      bulk_action_resource ->
        bulk_action_resource
        |> Ash.Query.for_read(:fetch_for_user_by_id, %{
          id: bulk_action_id,
          user_id: Owner.worker_key(scope(socket))
        })
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, bulk_action} -> bulk_action
          {:error, _} -> nil
        end
    end
  end

  # Pattern-matches the `:one_unresolved_per_user` identity violation.
  # AshPostgres maps the partial-unique-index violation back to the
  # identity's key (`:user_id`).
  defp unresolved_run_violation?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &user_id_uniqueness_error?/1)
  end

  defp user_id_uniqueness_error?(%{field: :user_id}), do: true
  defp user_id_uniqueness_error?(%{fields: fields}) when is_list(fields), do: :user_id in fields
  defp user_id_uniqueness_error?(_), do: false

  # Allocates one upload slot per field whose resolved handler declares a
  # non-nil `companion_requirement/1`, and releases slots no longer in the
  # desired set (e.g. user switched to a resource/action without that
  # field) so per-LV memory tracks current state.
  # `:companion_upload_names` tracks names currently allocated so we
  # don't double-allocate or pick up LiveView's internal phx-id keys
  # when scanning `socket.assigns.uploads`.
  defp sync_companion_uploads(socket) do
    desired = desired_companion_uploads(socket.assigns.options)
    allocated_names = Map.get(socket.assigns, :companion_upload_names, MapSet.new())
    desired_names = MapSet.new(Map.keys(desired))

    fresh = MapSet.difference(desired_names, allocated_names)
    stale = MapSet.difference(allocated_names, desired_names)

    {socket, released} = release_stale_companion_uploads(socket, stale)

    socket =
      Enum.reduce(fresh, socket, fn name, acc ->
        requirement = Map.fetch!(desired, name)

        # `external: &presign_companion/2` so the browser PUTs the bytes
        # straight to storage staging — they never touch the LV node.
        # `auto_upload: true` keeps the per-field form (`#field__<name>`)
        # uploading on file-pick so the entry is `done?: true` by submit
        # time. The worker downloads the staged blob later.
        allow_upload(acc, name,
          accept: requirement.accept,
          max_entries: 1,
          max_file_size: requirement.max_bytes,
          auto_upload: true,
          external: &presign_companion/2
        )
      end)

    retained = MapSet.difference(allocated_names, released)
    assign(socket, :companion_upload_names, MapSet.union(retained, fresh))
  end

  # `disallow_upload/2` raises if the slot has any entries (completed or in
  # progress), and on switch we sometimes have a staged companion blob in
  # the old slot. Skip those — the slot stays registered, dies with the LV,
  # and the re-allocation guard above prevents a duplicate `allow_upload`
  # if the user navigates back to the same field.
  defp release_stale_companion_uploads(socket, stale) do
    Enum.reduce(stale, {socket, MapSet.new()}, fn name, {acc, released} ->
      case acc.assigns[:uploads][name] do
        %{entries: []} -> {disallow_upload(acc, name), MapSet.put(released, name)}
        _ -> {acc, released}
      end
    end)
  end

  # Browser-to-storage presigner for companion uploads. The staging key is
  # namespaced under the user's `worker_key/1` prefix so the `BulkAction`
  # `:create` trust-boundary check can validate that every
  # persisted companion key starts with `bulk-staging/<user_prefix>/`.
  # The prefix and `entry.uuid` are server-computed; the trailing filename
  # is browser-supplied, so it is slugified via `safe_filename/1` to strip
  # path components — otherwise a `client_name` like `../../public/x` could
  # traverse out of the staging prefix.
  defp presign_companion(entry, socket) do
    user_prefix = socket |> scope() |> Owner.worker_key() |> to_string()
    filename = safe_filename(entry.client_name)
    key = "bulk-staging/#{user_prefix}/#{entry.uuid}/companions/#{filename}"

    url =
      ExampleWeb.Bulk.Storage.presigned_put_url(key,
        content_type: entry.client_type,
        content_length: entry.client_size
      )

    {:ok, %{uploader: "Put", key: key, url: url}, socket}
  end

  # Slugifies a browser-supplied filename into a key-safe segment.
  # `Path.basename/2`
  # + the `[^a-z0-9]+` collapse strip directory components and `..`, so the
  # trailing filename can never traverse out of the staging prefix; the
  # extension is slugged the same way so no unsafe byte survives in the key.
  defp safe_filename(name) when is_binary(name) do
    ext = name |> Path.extname() |> slug_extension()

    base =
      name
      |> Path.basename(Path.extname(name))
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    case base do
      "" -> "file" <> ext
      base -> base <> ext
    end
  end

  defp safe_filename(_), do: "file"

  # Slugs a `.ext` down to its leading dot plus `[a-z0-9]` only, dropping the
  # extension entirely when nothing survives.
  defp slug_extension("." <> rest) do
    case rest |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "") do
      "" -> ""
      cleaned -> "." <> cleaned
    end
  end

  defp slug_extension(_), do: ""

  defp desired_companion_uploads(options) do
    options
    |> ViewOptions.fields()
    |> Enum.flat_map(fn field ->
      case ViewOptions.companion_requirement_for(field) do
        nil -> []
        requirement -> [{ViewOptions.companion_upload_name(field), requirement}]
      end
    end)
    |> Map.new()
  end

  defp assign_csv_keys(%{assigns: %{uploaded_file: %{sheet: %{headers: headers}}}} = socket) do
    assign(socket, csv_keys: [nil | headers])
  end

  defp assign_csv_keys(socket) do
    assign(socket, csv_keys: [nil])
  end

  defp auto_fill_field_mappings(socket) do
    socket.assigns.options
    |> ViewOptions.fields()
    |> Enum.reduce(socket, fn %AshBulkDurable.Sheet.Field{field: %{name: name}}, socket ->
      field_name = to_string(name)

      if field_name in socket.assigns.csv_keys do
        options = ViewOptions.update_mapping(socket.assigns.options, field_name, field_name)
        assign(socket, options: options)
      else
        socket
      end
    end)
  end

  # An upload's temporary path has no extension; the browser's file name
  # says which type it is.
  defp read_sheet!(path, entry) do
    type = if String.ends_with?(entry.client_name, ".xlsx"), do: :xlsx, else: :csv
    {:ok, sheet} = AshBulkDurable.read_sheet(path, type: type)
    sheet
  end

  defp reset_upload(socket) do
    socket.assigns.uploads.sheet.entries
    |> Enum.reduce(socket, &cancel_upload(&2, :sheet, &1.ref))
    |> assign(uploaded_file: nil, errors: [])
    |> assign_csv_keys()
  end

  defp push_options(socket, options) do
    params = ViewOptions.to_url_params(options)
    base = bulk_path(socket)

    socket
    |> assign(errors: [])
    |> push_patch(to: "#{base}?#{URI.encode_query(params)}" |> String.trim_trailing("?"))
  end

  # Rebuilds the `?resource=…&action=…&mapping[…]=…` URL params from a bulk action's
  # persisted settings, via the same `ViewOptions.to_url_params/1` the form
  # itself uses. `handle_params` then re-validates everything (allowed
  # resource for the actor, action exists, mapping shape) on the way back in.
  # If the bulk action's resource or action no longer exists in the app, fall back to
  # the bare form rather than crashing the click.
  defp bulk_action_settings_params(bulk_action) do
    mapping = Mapping.from_bulk_action(bulk_action)

    ViewOptions.to_url_params(%{
      resource: mapping.resource,
      action: mapping.action,
      identity: mapping.identity,
      mapping: mapping.columns,
      rel_identities: mapping.rel_identities
    })
  rescue
    _stale_bulk_action -> %{}
  end

  # Returns `:ok` if every (mapped) field whose resolved handler declared a
  # `companion_requirement/1` has a fully-uploaded entry. Otherwise returns
  # `{:in_progress, names}` (entries are still uploading — submit was
  # clicked too early) or `{:missing, names}` (no file picked at all).
  # `:in_progress` takes precedence so the user sees the actionable message
  # — once those finish, a separate `:missing` would surface on retry.
  defp validate_required_companions(socket, fields) do
    uploads = socket.assigns.uploads || %{}

    {missing, in_progress} =
      Enum.reduce(fields, {[], []}, fn field, {missing, in_progress} ->
        case companion_status(field, uploads) do
          :ok -> {missing, in_progress}
          :missing -> {[field.field.name | missing], in_progress}
          :in_progress -> {missing, [field.field.name | in_progress]}
        end
      end)

    cond do
      in_progress != [] -> {:in_progress, Enum.reverse(in_progress)}
      missing != [] -> {:missing, Enum.reverse(missing)}
      true -> :ok
    end
  end

  defp companion_status(field, uploads) do
    case ViewOptions.companion_requirement_for(field) do
      nil -> :ok
      _requirement -> upload_state(Map.get(uploads, ViewOptions.companion_upload_name(field)))
    end
  end

  defp upload_state(nil), do: :missing
  defp upload_state(%{entries: []}), do: :missing

  defp upload_state(%{entries: entries}) do
    if Enum.all?(entries, & &1.done?), do: :ok, else: :in_progress
  end

  # Pulls each companion upload's storage staging key off the socket and keys it
  # by field name, giving the `%{field_name => key}` map
  # `AshBulkDurable.Sheet.stage/3` takes as `:companions`.
  defp consume_companion_keys(socket, fields) do
    fields
    |> Enum.flat_map(&consume_one_companion(socket, &1))
    |> Map.new()
  end

  defp consume_one_companion(socket, field) do
    case ViewOptions.companion_requirement_for(field) do
      nil ->
        []

      _requirement ->
        consume_uploaded_entries(
          socket,
          ViewOptions.companion_upload_name(field),
          fn meta, _entry -> {:ok, {field.field.name, meta.key}} end
        )
    end
  end

  defp mapped_fields(fields, mapping) do
    Enum.filter(fields, &Map.has_key?(mapping, &1.field.name))
  end
end
