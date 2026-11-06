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

  alias AshBulkDurable.Core.{
    CrashedRowError,
    NoMatchError,
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

  defp word(%StoredError{error: %NoMatchError{field: field} = error}),
    do: [on_field(field, no_match(error))]

  defp word(%StoredError{error: error, message: message}) do
    case form_errors(error) do
      [] -> [message]
      worded -> worded
    end
  end

  defp no_match(%NoMatchError{resource: nil}), do: gettext("no match found")

  defp no_match(%NoMatchError{resource: resource, criteria: criteria}) do
    gettext("no result in %{resource} matches %{criteria}",
      resource: ExampleWeb.Bulk.Utils.humanize(Ash.Resource.Info.short_name(resource)),
      criteria:
        Enum.map_join(criteria, ", ", fn {key, value} ->
          "#{ExampleWeb.Bulk.Utils.field_label(key, resource)} = \"#{Sheet.FieldHandler.cell(value)}\""
        end)
    )
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

  defp on_field(field, message) when field in [nil, :_form], do: message

  defp on_field(field, message) do
    gettext("%{field}: %{message}",
      field: ExampleWeb.Bulk.Utils.humanize(field),
      message: message
    )
  end
end
