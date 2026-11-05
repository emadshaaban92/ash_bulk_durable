defmodule ExampleWeb.Bulk.ErrorsSheet do
  @moduledoc """
  Serves a bulk action's errors sheet (`AshBulkDurable.errors_sheet/2`) for
  download, its errors worded in the reader's language.

  `build/1` returns a `Stream` of CSV iodata; `generate_url/1` streams that
  to a temp file, uploads it to storage, and returns a short-lived presigned
  download URL — a browser→storage presigned-download pattern, so there's no
  app-side controller or route.

  The object lives under the bulk action's `bulk-staging/` prefix, so the
  `AshBulkDurable.Core.PurgeStaleStaging` orphan sweep reclaims stale sheets after
  24h with no extra cleanup path — they're regenerated on demand anyway.
  """

  # The presigned GET is consumed almost immediately — the LiveView builds it
  # on click and hands the browser a download link. Pin a deliberately short
  # TTL here rather than inheriting the storage adapter's default, so the
  # window stays small regardless of how a host configures its default.
  @download_ttl_seconds 300

  @doc """
  Builds the errors sheet, uploads it to storage, and returns
  `{:ok, presigned_get_url}` (a download-forcing URL with a short TTL) or
  `{:error, term}` if the upload fails.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def generate_url(bulk_action) do
    {:ok, tmp_path} = Briefly.create(extname: ".csv")

    bulk_action
    |> build()
    |> Stream.into(File.stream!(tmp_path, [:write, :utf8]))
    |> Stream.run()

    key = object_key(bulk_action)
    filename = "errors_sheet_#{bulk_action.id}.csv"

    case ExampleWeb.Bulk.Storage.upload(key, tmp_path, content_type: "text/csv") do
      :ok ->
        {:ok,
         ExampleWeb.Bulk.Storage.presigned_get_url(key,
           expires_in: @download_ttl_seconds,
           query_params: [
             {"response-content-disposition", ~s(attachment; filename="#{filename}")}
           ]
         )}

      {:error, term} ->
        {:error, term}
    end
  end

  @doc "Storage key for a bulk action's errors sheet (under its staging prefix)."
  def object_key(bulk_action),
    do: "bulk-staging/#{bulk_action.user_id}/#{bulk_action.id}/errors_sheet.csv"

  def build(bulk_action) do
    bulk_action
    |> AshBulkDurable.errors_sheet(error: &ExampleWeb.Bulk.ErrorMessage.display/1)
    |> AshBulkDurable.Sheet.to_csv()
  end
end
