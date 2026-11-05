defmodule AshBulkDurable.Core.StoredError do
  @moduledoc """
  One refusal a bulk action keeps: the leaf exception, stripped of what is
  heavy or personal, and its English message taken when it was stored.

  The exception is kept so the screens can word it in the reader's language
  and put it on the field it names; the message is what they show when they
  cannot, including when the exception no longer decodes (its module was
  renamed, so `:safe` refuses the atom). The core never words an error.
  """

  defstruct [:error, :message]

  @type t :: %__MODULE__{error: Exception.t() | nil, message: String.t()}

  # A policy refusal carries the actor and everything it was checked
  # against; the rest carry the whole changeset or query.
  @stripped [:stacktrace, :changeset, :query, :subject, :actor, :facts, :filter, :policies]

  @doc "The refusals in `error`, one per leaf exception."
  def from(%__MODULE__{} = stored), do: [stored]
  def from(%Ash.Changeset{errors: errors}), do: errors |> Enum.flat_map(&from/1) |> uniq()
  def from(errors) when is_list(errors), do: errors |> Enum.flat_map(&from/1) |> uniq()
  def from(message) when is_binary(message), do: [%__MODULE__{message: tidy(message)}]

  def from(error) when is_exception(error) do
    error |> leaves() |> Enum.map(&store/1) |> uniq()
  end

  def from(term), do: [%__MODULE__{message: inspect(term)}]

  defp leaves(error) do
    if Ash.Error.ash_error?(error) do
      case error |> Ash.Error.to_error_class() |> Map.get(:errors, []) do
        [] -> [error]
        leaves -> leaves
      end
    else
      [error]
    end
  rescue
    _ -> [error]
  end

  defp store(error) do
    %__MODULE__{error: strip(error), message: message(error)}
  end

  defp strip(error) do
    error
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.filter(&(&1 in @stripped))
    |> Enum.reduce(error, &Map.put(&2, &1, nil))
    |> without_bread_crumbs()
  end

  defp message(error) do
    error |> without_bread_crumbs() |> Exception.message() |> tidy()
  end

  defp without_bread_crumbs(%{bread_crumbs: _} = error), do: Map.put(error, :bread_crumbs, [])
  defp without_bread_crumbs(error), do: error

  defp tidy(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp uniq(stored), do: Enum.uniq_by(stored, & &1.message)

  @doc false
  def encode(stored) do
    stored
    |> Enum.map(fn %__MODULE__{error: error, message: message} ->
      {message, error && :erlang.term_to_binary(error)}
    end)
    |> :erlang.term_to_binary()
  end

  @doc false
  def decode(binary) do
    binary
    |> :erlang.binary_to_term([:safe])
    |> Enum.map(fn {message, error} ->
      %__MODULE__{error: decode_error(error), message: message}
    end)
  end

  defp decode_error(nil), do: nil

  defp decode_error(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError -> nil
  end
end
