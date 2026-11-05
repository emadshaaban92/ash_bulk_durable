defmodule ExampleWeb.Bulk.CompanionUploadTest do
  @moduledoc """
  Step 5 coverage for the companion-upload mechanism switch:

    * The LV's `external: &presign_companion/2` presigner namespaces every
      staging key under `bulk-staging/<worker_key>/…` and returns it as the
      `:external` entry metadata (the `meta.key` the consume callback later
      reads).

  That staging refuses a key escaping the user's prefix is
  `test/ash_bulk_durable/sheet/companions_test.exs`'s.
  """
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # Test-only handler: claims Region's `:name` and declares a companion
  # upload so the `/bulk` page allocates a `companion__name` upload slot.
  defmodule CompanionProbe do
    @moduledoc false
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%AshBulkDurable.Sheet.Field{
          field: %{name: :name},
          resource: Example.Test.Region
        }),
        do: true

    def handles?(_), do: false

    @impl true
    def companion_requirement(_field), do: %{accept: ~w(.png .zip), max_bytes: 5_000_000}

    @impl true
    def input_value(_field, value, _ctx), do: {:ok, value}
  end

  defp put_handlers(handlers) do
    Example.Test.StorageHelpers.put_config(:field_handlers, handlers)
  end

  describe "presign_companion/2 (external uploader)" do
    setup do
      put_handlers([CompanionProbe])
      :ok
    end

    test "namespaces the staging key under bulk-staging/<worker_key>/ and returns it as meta",
         %{conn: conn, super_user: user} do
      {:ok, view, _html} =
        conn
        |> login_as(user)
        |> live(~p"/bulk")

      view
      |> element("#main_form select[name=resource_name]")
      |> render_change(%{"_target" => ["resource_name"], "resource_name" => "region"})

      view
      |> element("#main_form select[name=action_name]")
      |> render_change(%{"_target" => ["action_name"], "action_name" => "create"})

      file =
        file_input(view, "#field__name", :companion__name, [
          %{name: "logo.png", content: "fake-bytes", type: "image/png"}
        ])

      assert {:ok, %{entries: entries}} = preflight_upload(file)

      assert [%{uploader: "Put", key: key, url: url}] = Map.values(entries)
      assert String.starts_with?(key, "bulk-staging/#{user.id}/")
      assert String.ends_with?(key, "/companions/logo.png")
      assert is_binary(url)
    end
  end
end
