defmodule AshBulkDurable.Test.S3HookedClient do
  @moduledoc """
  `ExAws`'s hackney client, with a hook a test sets in its own process to
  act between two requests, as another writer would. Every request
  `AshBulkDurable.Storage.S3` makes runs in its caller's process, so the
  hook sees each of them, in order.
  """

  @behaviour ExAws.Request.HttpClient

  @doc "Calls `fun` with each request's method and URL, before sending it."
  def before_each(fun) when is_function(fun, 2), do: Process.put(__MODULE__, fun)

  @doc "Stops calling the hook."
  def clear, do: Process.delete(__MODULE__)

  @impl true
  def request(method, url, body, headers, http_opts) do
    with fun when is_function(fun, 2) <- Process.get(__MODULE__), do: fun.(method, url)
    ExAws.Request.Hackney.request(method, url, body, headers, http_opts)
  end
end
