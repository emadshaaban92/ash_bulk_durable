defmodule ExampleWeb.Bulk.Utils do
  @moduledoc """
  How the screens name a field. Humanized English here: an app with labels of
  its own swaps them in at this one place.
  """

  def humanize(name), do: Phoenix.Naming.humanize(name)

  def field_label(field, _resource), do: humanize(field)
end
