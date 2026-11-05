defmodule AshBulkDurable.Core.StoredTerm do
  @moduledoc """
  The target, input and tenant a bulk action and its rows keep. A term, as
  Ash's `:term`, except that one naming an atom this release no longer has
  reads as `%Unreadable{}` instead of raising: a deploy that removes a field
  or a module must not stop an owner reading, or abandoning, what they parked.
  `:safe` stays, as nothing else bounds what a stored term can add to the atom
  table.
  """
  use Ash.Type

  defmodule Unreadable do
    @moduledoc "Stands in for a stored term that no longer decodes."
    defstruct []
  end

  @columns [:target, :input, :tenant, :resolved_tenant]

  @impl true
  def storage_type(_constraints), do: :binary

  @impl true
  def cast_input(value, _constraints), do: {:ok, value}

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  # sobelow_skip ["Misc.BinToTerm"]
  def cast_stored(value, _constraints) do
    {:ok, Ash.Helpers.non_executable_binary_to_term(value, [:safe])}
  rescue
    ArgumentError -> {:ok, %Unreadable{}}
  end

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints), do: {:ok, :erlang.term_to_binary(value)}

  @doc "Whether a bulk action or a row holds a column that no longer decodes."
  def unreadable?(record) do
    record
    |> Map.take(@columns)
    |> Enum.any?(&match?({_column, %Unreadable{}}, &1))
  end
end
