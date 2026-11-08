defmodule ExampleWeb.Bulk.ErrorMessage do
  @moduledoc """
  Words a bulk action's stored refusals (`AshBulkDurable.Core.StoredError`)
  for the person reading them — the errors sheet, the progress panel and the
  sheet preview — in the current locale.

  An exception a form knows how to show is worded as a form words it, on the
  field it names; any other, or one that no longer decoded, reads as the
  English message kept beside it. What the code raised says nothing to the
  reader and can hold SQL, so it reads as one sentence; `Runner.row_raised/3`
  logged the detail.
  """
  use Gettext, backend: ExampleWeb.Gettext

  import AshBulkDurable.Core.Reference, only: [is_composite: 1]

  alias AshBulkDurable.Core.{
    CrashedRowError,
    ManyMatchesError,
    NoMatchError,
    RowExitError,
    RowTimeoutError,
    StagedFileError,
    StoredError,
    UnreadableRowError
  }

  alias AshBulkDurable.Sheet

  @doc "Stored refusals as one line in the current locale; `nil` reads as nothing."
  def display(nil), do: ""

  def display(stored) when is_list(stored) do
    stored |> Enum.flat_map(&word/1) |> Enum.uniq() |> Enum.join("; ")
  end

  @doc "Any error, worded as it would read once stored."
  def display_error(error), do: error |> StoredError.from() |> display()

  defp word(%StoredError{error: %Ash.Error.Unknown.UnknownError{}}),
    do: [gettext("This row hit an unexpected error, so nothing was saved for it.")]

  defp word(%StoredError{error: %RowExitError{}}),
    do: [gettext("This row hit an unexpected error, so nothing was saved for it.")]

  defp word(%StoredError{error: %RowTimeoutError{}}),
    do: [gettext("This row took too long to prepare, so nothing was saved for it.")]

  defp word(%StoredError{error: %StagedFileError{}}),
    do: [
      gettext(
        "A file uploaded with this bulk action couldn't be read, so nothing was saved for this row."
      )
    ]

  defp word(%StoredError{error: %CrashedRowError{}}),
    do: [
      gettext(
        "This row stopped the bulk action each time it ran, so it was not run again and nothing was saved for it."
      )
    ]

  defp word(%StoredError{error: %UnreadableRowError{}}),
    do: [gettext("What this row held no longer exists, so nothing was saved for it.")]

  defp word(%StoredError{error: %NoMatchError{field: nil, resource: resource} = error})
       when not is_nil(resource),
       do: [on_fields(target_keys(error), no_match(error))]

  defp word(%StoredError{error: %NoMatchError{field: field} = error}),
    do: [on_field(field, no_match(error))]

  defp word(%StoredError{error: %ManyMatchesError{field: nil, resource: resource} = error})
       when not is_nil(resource),
       do: [on_fields(target_keys(error), many_matches(error))]

  defp word(%StoredError{error: %ManyMatchesError{field: field} = error}),
    do: [on_field(field, many_matches(error))]

  defp word(%StoredError{error: error, message: message}) do
    case form_errors(error) do
      [] -> [message]
      worded -> worded
    end
  end

  defp no_match(%NoMatchError{resource: nil}), do: gettext("no match found")

  defp no_match(%NoMatchError{resource: resource, criteria: criteria}) when criteria == %{},
    do: gettext("the row names no %{resource}", resource: resource_label(resource))

  defp no_match(%NoMatchError{resource: resource, criteria: criteria}) do
    gettext("no result in %{resource} matches %{criteria}",
      resource: resource_label(resource),
      criteria: criteria_label(criteria, resource)
    )
  end

  # An update's or destroy's target names no field: it reads on the keys the
  # row looked it up by, not on a clause through a relationship, which only
  # narrows the lookup (the message names that clause).
  defp target_keys(%{criteria: criteria}) do
    for {key, value} <- ManyMatchesError.in_order(criteria), not is_composite(value), do: key
  end

  defp many_matches(%ManyMatchesError{resource: nil}), do: gettext("more than one match found")

  defp many_matches(%ManyMatchesError{resource: resource, criteria: criteria}) do
    gettext("more than one result in %{resource} matches %{criteria}",
      resource: resource_label(resource),
      criteria: criteria_label(criteria, resource)
    )
  end

  defp resource_label(resource),
    do: ExampleWeb.Bulk.Utils.humanize(Ash.Resource.Info.short_name(resource))

  # A clause through a relationship is labelled by the related resource's
  # own fields, under the relationship's label, however deep it goes.
  defp criteria_label(criteria, resource, under \\ nil) do
    criteria
    |> ManyMatchesError.in_order()
    |> Enum.map_join(", ", &criterion_label(&1, resource, under))
  end

  defp criterion_label({key, nested}, resource, under) when is_composite(nested),
    do: criteria_label(nested, related(resource, key), label(key, resource, under))

  defp criterion_label({key, value}, resource, under),
    do: "#{label(key, resource, under)} = \"#{Sheet.FieldHandler.cell(value)}\""

  defp label(key, resource, nil), do: ExampleWeb.Bulk.Utils.field_label(key, resource)
  defp label(key, resource, under), do: "#{under} #{label(key, resource, nil)}"

  defp related(resource, key) do
    case Ash.Resource.Info.relationship(resource, key) do
      %{destination: destination} -> destination
      nil -> resource
    end
  end

  defp form_errors(error) when is_exception(error) do
    case AshPhoenix.FormData.Error.impl_for(error) do
      nil -> []
      impl -> error |> impl.to_form_error() |> List.wrap() |> Enum.flat_map(&word_form_error/1)
    end
  end

  defp form_errors(_none), do: []

  defp word_form_error({field, message, vars}) when is_binary(message) and message != "" do
    [on_field(field, ExampleWeb.CoreComponents.translate_error({message, vars}))]
  end

  defp word_form_error(_said_nothing), do: []

  defp on_fields([], message), do: message

  defp on_fields(fields, message) do
    gettext("%{field}: %{message}",
      field: Enum.map_join(fields, ", ", &ExampleWeb.Bulk.Utils.humanize/1),
      message: message
    )
  end

  defp on_field(field, message) when field in [nil, :_form], do: message

  defp on_field(field, message) do
    gettext("%{field}: %{message}",
      field: ExampleWeb.Bulk.Utils.humanize(field),
      message: message
    )
  end
end
