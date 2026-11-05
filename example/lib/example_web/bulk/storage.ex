defmodule ExampleWeb.Bulk.Storage do
  @moduledoc """
  What the screens need of the object store beyond what the engine reads:
  presigning a browser's companion upload, and uploading the errors sheet
  and presigning its download. The configured `:storage` adapter implements
  this beside `AshBulkDurable.Core.Storage`, so one adapter serves both;
  `Example.BulkActions.LocalStorage` is this app's.
  """

  @doc """
  Streams a local file up to `key` server-side (the errors sheet).
  Opts: `:content_type`.
  """
  @callback upload(key :: String.t(), path :: Path.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Returns a presigned PUT URL for a browser→storage companion upload.
  Opts: `:content_type` (a signed query parameter, which an object store ignores),
  `:content_length` (a signed *header*, so an over-long body fails
  signature validation).
  """
  @callback presigned_put_url(key :: String.t(), opts :: keyword()) :: String.t()

  @doc """
  Returns a short-lived presigned GET URL for a server-generated object,
  e.g. the errors sheet. Opts: `:query_params` (extra signed params
  such as a `response-content-disposition` to force a download).
  """
  @callback presigned_get_url(key :: String.t(), opts :: keyword()) :: String.t()

  def upload(key, path, opts \\ []), do: impl().upload(key, path, opts)
  def presigned_put_url(key, opts \\ []), do: impl().presigned_put_url(key, opts)
  def presigned_get_url(key, opts \\ []), do: impl().presigned_get_url(key, opts)

  defp impl, do: AshBulkDurable.config(:storage)
end
