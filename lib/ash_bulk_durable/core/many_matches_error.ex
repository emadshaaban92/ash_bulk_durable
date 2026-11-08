defmodule AshBulkDurable.Core.ManyMatchesError do
  @moduledoc """
  What fails a row whose lookup found more than one record: the `field` it
  was for, the `resource` it looked in and the `criteria` it looked by, for
  whoever words it. The row names no one record, so nothing is written for
  it rather than writing to one of them. A resolver's reference names
  neither, only that it found more than one.
  """
  use Splode.Error, fields: [:field, :resource, criteria: %{}], class: :invalid

  def message(%{resource: nil}), do: "more than one match found"

  def message(%{resource: resource, criteria: criteria}) do
    "more than one #{label(resource)} matches #{Enum.map_join(criteria, ", ", &criterion/1)}"
  end

  defp criterion({key, value}), do: "#{key} = #{inspect(value)}"

  defp label(resource) do
    resource
    |> Ash.Resource.Info.short_name()
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
