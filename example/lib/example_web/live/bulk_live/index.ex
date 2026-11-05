defmodule ExampleWeb.BulkLive.Index do
  use ExampleWeb.Bulk.LiveView

  @impl ExampleWeb.Bulk.LiveView
  def scope(socket), do: socket.assigns.scope

  @impl ExampleWeb.Bulk.LiveView
  def bulk_path, do: "/bulk"
end
