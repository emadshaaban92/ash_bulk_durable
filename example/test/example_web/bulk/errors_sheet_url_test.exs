defmodule ExampleWeb.Bulk.ErrorsSheetUrlTest do
  @moduledoc """
  Tests for `ErrorsSheet.generate_url/1`: the sheet is streamed up through
  the configured storage adapter as `text/csv` and returned as a presigned
  URL pinned to an explicit short TTL and a download filename.

  `async: false` — each test swaps the global `:ash_bulk_durable` storage
  adapter via app env.
  """
  use Example.DataCase, async: false

  import Example.Test.StorageHelpers

  require Ash.Query

  alias ExampleWeb.Bulk.ErrorsSheet
  alias Example.BulkActions.{BulkAction, Row}

  # Capturing storage adapter — `generate_url/1` bulk actions synchronously in the
  # test process, so messages it sends land in this test's mailbox for
  # `assert_received`. Records the upload and the presign opts (the TTL we
  # want to pin) while returning the deterministic stub URL.
  defmodule CapturingStorage do
    @moduledoc false
    @behaviour AshBulkDurable.Core.Storage
    @behaviour ExampleWeb.Bulk.Storage

    @impl true
    def get_object(_key), do: {:error, :not_stubbed}

    @impl true
    def delete_object(_key), do: :ok

    @impl true
    def list_objects(_prefix), do: {:ok, []}

    @impl true
    def presigned_put_url(key, _opts), do: "https://test.local/put/#{key}"

    @impl true
    # sobelow_skip ["Traversal.FileModule"]
    def upload(key, path, opts) do
      send(self(), {:upload, key, File.read!(path), opts})
      :ok
    end

    @impl true
    def presigned_get_url(key, opts) do
      send(self(), {:presigned_get_url, key, opts})
      "https://test.local/get/#{key}"
    end
  end

  defmodule FailingUploadStorage do
    @moduledoc false
    @behaviour AshBulkDurable.Core.Storage
    @behaviour ExampleWeb.Bulk.Storage

    @impl true
    def get_object(_key), do: {:error, :not_stubbed}

    @impl true
    def delete_object(_key), do: :ok

    @impl true
    def list_objects(_prefix), do: {:ok, []}

    @impl true
    def presigned_put_url(key, _opts), do: "https://test.local/put/#{key}"

    @impl true
    def presigned_get_url(key, _opts), do: "https://test.local/get/#{key}"

    @impl true
    def upload(_key, _path, _opts), do: {:error, :upload_offline}
  end

  defp create_bulk_action! do
    Ash.create!(
      BulkAction,
      %{
        user_id: Ecto.UUID.generate(),
        resource_name: "Example.Test.Region",
        action_name: :create,
        action_type: :create,
        total_rows: 3,
        mode: :per_row,
        chunk_size: 50,
        rows:
          Enum.map(
            1..3,
            &%{
              input: %{name: "Region #{&1}", native_name: "AR #{&1}", code: "G#{&1}"}
            }
          )
      },
      action: :create,
      authorize?: false
    )
  end

  defp rows(bulk_action_id) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp fail!(row, message) do
    Ash.update!(row, %{error: message}, action: :mark_failed, authorize?: false)
  end

  describe "generate_url/1" do
    test "uploads the sheet and returns a presigned URL with an explicit short TTL" do
      put_storage(CapturingStorage)

      bulk_action = create_bulk_action!()
      [_r1, r2, _r3] = rows(bulk_action.id)
      fail!(r2, "bad name")

      key = ErrorsSheet.object_key(bulk_action)
      assert {:ok, "https://test.local/get/" <> ^key} = ErrorsSheet.generate_url(bulk_action)

      # The CSV was streamed up server-side as text/csv and carries the row's
      # error summary.
      assert_received {:upload, ^key, body, upload_opts}
      assert upload_opts[:content_type] == "text/csv"
      assert body =~ "bad name"

      # The presign pins an explicit expiry rather than inheriting the storage
      # adapter's default, and forces a download under the bulk action's filename.
      assert_received {:presigned_get_url, ^key, get_opts}
      assert get_opts[:expires_in] == 300

      assert {"response-content-disposition", disposition} =
               List.keyfind(get_opts[:query_params], "response-content-disposition", 0)

      assert disposition =~ "errors_sheet_#{bulk_action.id}.csv"
    end

    test "returns {:error, term} when the upload fails" do
      put_storage(FailingUploadStorage)

      bulk_action = create_bulk_action!()
      [_r1, r2, _r3] = rows(bulk_action.id)
      fail!(r2, "bad name")

      assert {:error, :upload_offline} = ErrorsSheet.generate_url(bulk_action)
    end
  end
end
