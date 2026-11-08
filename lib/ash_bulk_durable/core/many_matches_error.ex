defmodule AshBulkDurable.Core.ManyMatchesError do
  @moduledoc """
  What fails a row whose lookup found more than one record: the `field` it
  was for, the `resource` it looked in and the `criteria` it looked by, for
  whoever words it. The row names no one record, so nothing is written for
  it rather than writing to one of them. A resolver's reference names
  neither, only that it found more than one. An update or destroy whose
  target lookup matches more than one record names no `field`, its
  `criteria` being the row's whole lookup, where a key through a
  relationship holds a map of that relationship's keys.
  """
  use Splode.Error, fields: [:field, :resource, criteria: %{}], class: :invalid

  import AshBulkDurable.Core.Reference, only: [is_composite: 1]

  def message(%{resource: nil}), do: "more than one match found"

  def message(%{resource: resource, criteria: criteria}) do
    "more than one #{label(resource)} matches #{criteria_text(criteria)}"
  end

  @doc """
  The criteria in the order they read: the keys looked up by, then each
  clause through a relationship, by name within each. A map's own order
  varies between runs.
  """
  def in_order(criteria),
    do: Enum.sort_by(criteria, fn {key, value} -> {is_composite(value), to_string(key)} end)

  defp criteria_text(criteria),
    do: criteria |> in_order() |> Enum.map_join(", ", &criterion/1)

  defp criterion({key, nested}) when is_composite(nested),
    do: nested |> Map.new(fn {sub_key, sub} -> {"#{key}.#{sub_key}", sub} end) |> criteria_text()

  defp criterion({key, value}), do: "#{key} = #{inspect(value)}"

  defp label(resource) do
    resource
    |> Ash.Resource.Info.short_name()
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
