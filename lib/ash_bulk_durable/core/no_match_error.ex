defmodule AshBulkDurable.Core.NoMatchError do
  @moduledoc """
  What fails a row whose lookup found nothing: the `field` it was for, the
  `resource` it looked in and the `criteria` it looked by, for whoever words
  it. A resolver's reference names neither, only that it found no match. An
  update or destroy whose target lookup matches nothing names no `field`,
  its `criteria` being the row's whole lookup, where a key through a
  relationship holds a map of that relationship's keys, as
  `AshBulkDurable.Core.ManyMatchesError` does.
  """
  use Splode.Error, fields: [:field, :resource, criteria: %{}], class: :invalid

  alias AshBulkDurable.Core.ManyMatchesError

  def message(%{resource: nil}), do: "no match found"

  def message(%{resource: resource, criteria: criteria}) when criteria == %{},
    do: "the row names no #{ManyMatchesError.label(resource)}"

  def message(%{resource: resource, criteria: criteria}) do
    "no #{ManyMatchesError.label(resource)} matches #{ManyMatchesError.criteria_text(criteria)}"
  end
end
