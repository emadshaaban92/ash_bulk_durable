defmodule AshBulkDurable.Core.NoMatchError do
  @moduledoc """
  What fails a row whose reference found nothing: the `field` it was for, the
  `resource` it looked in and the `criteria` it looked by, for whoever words
  it. A resolver's reference names neither, only that it found no match.
  """
  use Splode.Error, fields: [:field, :resource, criteria: %{}], class: :invalid

  def message(%{resource: nil}), do: "no match found"

  def message(%{resource: resource, criteria: criteria}) do
    "no #{label(resource)} matches #{Enum.map_join(criteria, ", ", &criterion/1)}"
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
