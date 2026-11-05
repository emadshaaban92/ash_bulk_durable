defmodule AshBulkDurable.Core.StoredErrors do
  @moduledoc """
  An Ash type for a list of `AshBulkDurable.Core.StoredError`s, kept as
  Erlang terms. Casting accepts any error as Ash or a bulk result hands it
  over (an exception, an errored changeset, a list, a message), so callers
  pass the error itself.

  The column holds the messages and each exception encoded on its own: the
  outer term is only strings and binaries, so it always decodes, and an
  exception that no longer does leaves its message behind. Stored errors
  cannot be queried in SQL.
  """
  use Ash.Type

  alias AshBulkDurable.Core.StoredError

  @impl Ash.Type
  def storage_type(_constraints), do: :binary

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(error, _constraints), do: {:ok, StoredError.from(error)}

  @impl Ash.Type
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(binary, _constraints) when is_binary(binary),
    do: {:ok, StoredError.decode(binary)}

  def cast_stored(_value, _constraints), do: :error

  @impl Ash.Type
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(stored, _constraints) when is_list(stored),
    do: {:ok, StoredError.encode(stored)}

  def dump_to_native(_value, _constraints), do: :error
end
