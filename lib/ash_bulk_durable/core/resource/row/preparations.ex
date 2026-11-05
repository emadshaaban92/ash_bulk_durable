defmodule AshBulkDurable.Core.Resource.Row.Preparations.LimitByChunkSize do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    chunk_size = Ash.Query.get_argument(query, :chunk_size)

    query
    |> Ash.Query.limit(chunk_size)
    |> Ash.Query.sort(row_index: :asc)
  end
end
