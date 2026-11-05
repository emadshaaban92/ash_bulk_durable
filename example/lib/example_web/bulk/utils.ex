defmodule ExampleWeb.Bulk.Utils do
  @moduledoc """
  How the screens name a field: the humanized English, translated by the
  `labels` Gettext domain. An app with labels of its own swaps them in at this
  one place.
  """

  def humanize(name),
    do: Gettext.dgettext(ExampleWeb.Gettext, "labels", Phoenix.Naming.humanize(name))

  def field_label(field, _resource), do: humanize(field)
end
