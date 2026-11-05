defmodule ExampleWeb.Bulk.CompanionBlockingTest do
  @moduledoc """
  Feature test for the required-companion submit guard on `/bulk`: a field
  whose handler declares a `companion_requirement/1` cannot be submitted
  until the user uploads the companion file. The screens label the upload
  from the requirement and the field's own label.

  The prepare → input_value → finish lifecycle is the sheet layer's,
  covered by `test/ash_bulk_durable/sheet/mapping_test.exs`; the check that
  a staged file meets the requirement by
  `test/ash_bulk_durable/sheet/companions_test.exs`.

  `async: false` because it mutates the global
  `config :ash_bulk_durable, field_handlers: …`.
  """
  use ExampleWeb.FeatureCase, async: false
  alias Example.Test.Region
  require Ash.Query

  defmodule CompanionRequired do
    @moduledoc "Declares a companion upload."
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%AshBulkDurable.Sheet.Field{
          field: %{name: :name},
          resource: Example.Test.Region
        }),
        do: true

    def handles?(_), do: false

    @impl true
    def companion_requirement(_field), do: %{accept: ~w(.csv), max_bytes: 1_000_000}

    @impl true
    def input_value(_field, value, _ctx), do: {:ok, value}
  end

  defp put_handlers(handlers) do
    Example.Test.StorageHelpers.put_config(:field_handlers, handlers)
  end

  defp valid_csv do
    """
    code,name,native_name
    LIFECYCLE1,Lifecycle Region 1,تجربة 1
    LIFECYCLE2,Lifecycle Region 2,تجربة 2
    """
  end

  defp upload_csv(session, content) do
    {:ok, path} = Briefly.create(extname: ".csv")
    File.write!(path, content)
    session |> upload("input[name='sheet']", "File", path)
  end

  # CSV column headers match Region attribute names — `auto_fill_field_mappings`
  # in the LiveView handles the per-field mapping for us.
  defp configure_region_mapping(session) do
    session
    |> select_change("Resource", option: "Region")
    |> select_change("Action", option: "Create")
    |> within("#main_form", &upload_csv(&1, valid_csv()))
  end

  describe "companion_requirement/1 + required-companion blocking" do
    setup do
      put_handlers([CompanionRequired])
      :ok
    end

    test "submit blocked with a clear flash when the companion isn't uploaded", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> configure_region_mapping()
      # Companion file input is rendered (handler declared a requirement)
      # but the user hasn't filled it in — submit must refuse.
      |> assert_has("label", text: "CSV for Name")
      |> click_button("Submit")
      |> assert_has("#flash-error", text: "Missing required file uploads")

      assert {:ok, []} =
               Region
               |> Ash.Query.filter(code in ["LIFECYCLE1", "LIFECYCLE2"])
               |> Ash.read(actor: super_user)
    end
  end
end
