defmodule ExampleWeb.StorageController do
  @moduledoc "Honours the signed URLs `Example.BulkActions.LocalStorage` hands out."
  use ExampleWeb, :controller

  alias Example.BulkActions.LocalStorage

  def put(conn, %{"token" => token}) do
    case LocalStorage.verify(token) do
      {:ok, %{method: :put, key: key, max_bytes: max_bytes}} ->
        write(conn, key, max_bytes)

      _refused ->
        send_resp(conn, 403, "")
    end
  end

  def get(conn, %{"token" => token}) do
    case LocalStorage.verify(token) do
      {:ok, %{method: :get, key: key, disposition: disposition}} ->
        conn
        |> put_resp_header("content-disposition", disposition)
        |> send_file(200, LocalStorage.path(key))

      _refused ->
        send_resp(conn, 403, "")
    end
  end

  defp write(conn, key, max_bytes) do
    case read_body(conn, length: max_bytes) do
      {:ok, body, conn} ->
        :ok = LocalStorage.put_object(key, body)
        send_resp(conn, 200, "")

      {_more_or_error, _rest, conn} ->
        send_resp(conn, 413, "")
    end
  end
end
