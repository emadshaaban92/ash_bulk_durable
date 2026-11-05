defmodule ExampleWeb.Bulk.Components.FieldMappingPanel do
  @moduledoc """
  Renders the per-field mapping configuration as a grid of cards — one card
  per field — instead of stuffing controls into table headers.

  Each card owns one field's configuration: the CSV-column mapping (or a
  set of sub-mappings for composite-key identities), the optional
  "lookup-by identity" dropdown for `belongs_to` fields, and any companion
  file input the field's handler asks for. A status badge in the top-right
  corner shows at a glance whether the field is mapped, partially mapped,
  or still missing required input.

  The card is laid out so the user picks the identity *first* (for
  `belongs_to` fields) — that choice may switch the CSV-mapping UI
  between one dropdown and one-per-key — and only then maps CSV columns
  underneath it.

  The component is purely presentational — events (`update_mapping`,
  `update_rel_identities`, `update_main_form`) bubble up to the parent
  LiveView, keeping the existing handler contract intact.

  Icons are rendered as bare `<span class="hero-..." />` so the component
  depends only on the Tailwind heroicons plugin, not on any host-app icon
  helper.
  """
  use Phoenix.Component
  use Gettext, backend: ExampleWeb.Gettext

  alias ExampleWeb.Bulk.Utils
  alias ExampleWeb.Bulk.ViewOptions

  attr :options, :any, required: true
  attr :csv_keys, :list, required: true
  attr :uploaded_file, :any, default: nil
  attr :uploads, :any, required: true

  def field_mapping_panel(assigns) do
    {identity_fields, other_fields} = ViewOptions.partition_fields(assigns.options)
    assigns = assign(assigns, identity_fields: identity_fields, other_fields: other_fields)

    ~H"""
    <%= if @identity_fields == [] do %>
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3 p-3 sm:p-4">
        <.field_card
          :for={bf <- @other_fields}
          bf={bf}
          options={@options}
          csv_keys={@csv_keys}
          uploaded_file={@uploaded_file}
          uploads={@uploads}
        />
      </div>
    <% else %>
      <div class="space-y-5 p-3 sm:p-4">
        <.field_section
          heading={gettext("Look up the row by")}
          description={gettext("Used to find the existing row in the database.")}
          fields={@identity_fields}
          options={@options}
          csv_keys={@csv_keys}
          uploaded_file={@uploaded_file}
          uploads={@uploads}
        />

        <.field_section
          :if={@other_fields != []}
          heading={gettext("Update these fields")}
          description={gettext("New values written to the row once it's found.")}
          fields={@other_fields}
          options={@options}
          csv_keys={@csv_keys}
          uploaded_file={@uploaded_file}
          uploads={@uploads}
        />
      </div>
    <% end %>
    """
  end

  attr :heading, :string, required: true
  attr :description, :string, default: nil
  attr :fields, :list, required: true
  attr :options, :any, required: true
  attr :csv_keys, :list, required: true
  attr :uploaded_file, :any, default: nil
  attr :uploads, :any, required: true

  defp field_section(assigns) do
    ~H"""
    <section>
      <div class="mb-2">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          {@heading}
        </h3>
        <p :if={@description} class="text-xs text-base-content/50 mt-0.5">
          {@description}
        </p>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
        <.field_card
          :for={bf <- @fields}
          bf={bf}
          options={@options}
          csv_keys={@csv_keys}
          uploaded_file={@uploaded_file}
          uploads={@uploads}
        />
      </div>
    </section>
    """
  end

  attr :bf, :any, required: true
  attr :options, :any, required: true
  attr :csv_keys, :list, required: true
  attr :uploaded_file, :any, default: nil
  attr :uploads, :any, required: true

  defp field_card(assigns) do
    assigns =
      assigns
      |> assign(
        :composite_keys,
        ViewOptions.composite_identity_keys(assigns.options, assigns.bf.field.name)
      )
      |> assign(:companion, ViewOptions.companion_requirement_for(assigns.bf))
      |> assign(:belongs_to?, ViewOptions.belongs_to?(assigns.bf))
      |> assign(:required?, ViewOptions.required?(assigns.bf, assigns.options))
      |> assign_new(:status, fn %{bf: bf, options: options, uploads: uploads} ->
        field_status(bf, options, uploads)
      end)

    ~H"""
    <.form
      for={%{}}
      id={"field__#{@bf.field.name}"}
      phx-change="update_main_form"
      class={[
        "card bg-base-100 border shadow-sm",
        status_border(@status)
      ]}
    >
      <div class="card-body p-4 gap-3">
        <div class="flex items-center justify-between gap-2 border-b border-base-300 pb-2">
          <div
            class="font-medium text-sm truncate"
            title={Utils.field_label(@bf.field.name, @bf.resource)}
          >
            {Utils.field_label(@bf.field.name, @bf.resource)}<span :if={@required?} class="text-error">&nbsp;*</span>
          </div>
          <.status_badge status={@status} />
        </div>

        <.select
          :if={@belongs_to?}
          id={"rel_identities__#{@bf.field.name}"}
          name={"rel_identities__#{@bf.field.name}"}
          label={gettext("Lookup by")}
          phx-change="update_rel_identities"
          value={@options |> ViewOptions.rel_identities_value(@bf.field.name)}
          options={@bf |> ViewOptions.rel_identities_select_opts()}
          required={@required?}
        />

        <%= case @composite_keys do %>
          <% nil -> %>
            <.select
              id={"mapping__#{@bf.field.name}"}
              name={"mapping__#{@bf.field.name}"}
              label={gettext("CSV column")}
              phx-change="update_mapping"
              value={@options |> ViewOptions.mapping_value(@bf.field.name)}
              options={@csv_keys}
              required={@required?}
              disabled={is_nil(@uploaded_file)}
            />
          <% keys -> %>
            <div class="space-y-2">
              <div class="text-xs text-base-content/60">{gettext("CSV columns")}</div>
              <.select
                :for={key <- keys}
                id={"mapping__#{@bf.field.name}__#{key}"}
                name={"mapping__#{@bf.field.name}__#{key}"}
                label={Utils.field_label(key, @bf.resource)}
                phx-change="update_mapping"
                value={@options |> ViewOptions.mapping_value(@bf.field.name, key)}
                options={@csv_keys}
                disabled={is_nil(@uploaded_file)}
              />
            </div>
        <% end %>

        <div :if={@companion}>
          <label
            class="label py-1"
            for={@uploads[ViewOptions.companion_upload_name(@bf)].ref}
          >
            {companion_label(@bf, @companion)}
          </label>
          <.live_file_input
            upload={@uploads[ViewOptions.companion_upload_name(@bf)]}
            class="file-input file-input-sm w-full"
          />
        </div>
      </div>
    </.form>
    """
  end

  # "ZIP for Photos": the file's format from the extensions it accepts, and
  # the field's own label.
  defp companion_label(%{field: field, resource: resource}, %{accept: accept}) do
    gettext("%{format} for %{field}",
      format: Enum.map_join(accept, "/", &(&1 |> String.trim_leading(".") |> String.upcase())),
      field: ExampleWeb.Bulk.Utils.field_label(field.name, resource)
    )
  end

  attr :status, :atom, required: true

  defp status_badge(%{status: :mapped} = assigns) do
    ~H"""
    <span class="badge badge-sm badge-success gap-1">
      <span class="hero-check w-3 h-3" /> {gettext("Mapped")}
    </span>
    """
  end

  defp status_badge(%{status: :file_needed} = assigns) do
    ~H"""
    <span class="badge badge-sm badge-warning gap-1">
      <span class="hero-paper-clip w-3 h-3" /> {gettext("File needed")}
    </span>
    """
  end

  defp status_badge(%{status: :partial} = assigns) do
    ~H"""
    <span class="badge badge-sm badge-warning gap-1">
      <span class="hero-exclamation-triangle w-3 h-3" /> {gettext("Partial")}
    </span>
    """
  end

  defp status_badge(%{status: :required_missing} = assigns) do
    ~H"""
    <span class="badge badge-sm badge-error gap-1">
      <span class="hero-exclamation-circle w-3 h-3" /> {gettext("Required")}
    </span>
    """
  end

  defp status_badge(%{status: :unmapped} = assigns) do
    ~H"""
    <span class="badge badge-sm badge-ghost">{gettext("Optional")}</span>
    """
  end

  defp status_border(:mapped), do: "border-success/40"
  defp status_border(:file_needed), do: "border-warning/50"
  defp status_border(:partial), do: "border-warning/50"
  defp status_border(:required_missing), do: "border-error/50"
  defp status_border(:unmapped), do: "border-base-300"

  # Status precedence: mapping shape comes first, then companion-upload
  # presence — a required CSV mapping with no value masks "file needed".
  defp field_status(bf, options, uploads) do
    case mapping_status(bf, options) do
      :mapped -> mapped_or_file_needed(bf, uploads)
      other -> other
    end
  end

  defp mapping_status(bf, options) do
    name = bf.field.name
    required? = ViewOptions.required?(bf, options)

    case ViewOptions.mapping_value(options, name) do
      empty when empty in [nil, ""] ->
        if required?, do: :required_missing, else: :unmapped

      %{} = sub_map ->
        composite_status(options, name, sub_map, required?)

      _csv_col ->
        :mapped
    end
  end

  defp composite_status(options, name, sub_map, required?) do
    case ViewOptions.composite_identity_keys(options, name) do
      nil ->
        :mapped

      keys ->
        filled = Enum.count(keys, fn k -> Map.get(sub_map, k) not in [nil, ""] end)

        cond do
          filled == length(keys) -> :mapped
          filled == 0 and not required? -> :unmapped
          filled == 0 -> :required_missing
          true -> :partial
        end
    end
  end

  defp mapped_or_file_needed(bf, uploads) do
    case ViewOptions.companion_requirement_for(bf) do
      nil ->
        :mapped

      _requirement ->
        case Map.get(uploads || %{}, ViewOptions.companion_upload_name(bf)) do
          %{entries: [_ | _]} -> :mapped
          _ -> :file_needed
        end
    end
  end

  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :name, :string
  attr :options, :list, default: [{nil, ""}]
  attr :value, :string, default: nil
  attr :rest, :global, include: ~w(disabled required)

  defp select(assigns) do
    ~H"""
    <div class="w-full">
      <label :if={@label && @label != ""} class="label py-1" for={@id || @name}>{@label}</label>
      <select id={@id || @name} name={@name} class="select select-sm w-full" {@rest}>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
    </div>
    """
  end
end
