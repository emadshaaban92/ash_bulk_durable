defmodule ExampleWeb.Bulk do
  @moduledoc """
  The `/bulk` screens over `ash_bulk_durable`. Their config sits under the
  app's `:bulk` key:

      config :example, :bulk, resources: [Example.Library.Book]

    * `:resources` — the resources `/bulk` offers; each action of theirs a
      policy allows the user is offered with them.
  """

  @doc "Reads one `:bulk` config key."
  def config(key, default \\ nil) do
    :example
    |> Application.get_env(:bulk, [])
    |> Keyword.get(key, default)
  end
end
