defmodule ExampleWeb.Bulk.ErrorsSheetTest do
  @moduledoc """
  The errors sheet as the screens serve it, its errors worded for the
  reader. What goes in it is `AshBulkDurable.Sheet.ErrorsSheetTest`'s.
  """
  use Example.DataCase, async: true

  require Ash.Query

  alias ExampleWeb.Bulk.ErrorsSheet
  alias Example.BulkActions.{BulkAction, Row}
  alias NimbleCSV.RFC4180, as: CSV

  defp create_bulk_action! do
    Ash.create!(
      BulkAction,
      %{
        user_id: Ecto.UUID.generate(),
        resource_name: "Example.Test.Region",
        action_name: :create,
        action_type: :create,
        total_rows: 2,
        mode: :per_row,
        chunk_size: 50,
        rows: [%{input: %{code: "B1"}}, %{input: %{code: "B2"}}]
      },
      action: :create,
      authorize?: false
    )
  end

  defp rows(bulk_action_id) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action_id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp decode(bulk_action) do
    bulk_action
    |> ErrorsSheet.build()
    |> Enum.to_list()
    |> IO.iodata_to_binary()
    |> CSV.parse_string(skip_headers: false)
  end

  describe "build/1" do
    test "words a stored exception as a form words it, in the reader's language" do
      bulk_action = create_bulk_action!()
      [row, _pending] = rows(bulk_action.id)

      error = Ash.Error.Changes.Required.exception(field: :name, type: :attribute)
      Ash.update!(row, %{error: error}, action: :mark_failed, authorize?: false)

      Gettext.put_locale("ar")
      on_exit(fn -> Gettext.put_locale("en") end)

      [header | [[id, last_error | _cells] | _rest]] = decode(bulk_action)

      assert Enum.take(header, 2) == ["row_id", "last_error"]
      assert id == row.id
      assert last_error == "الاسم: مطلوب"
    end

    test "words what a row raised as one sentence, keeping the raise's own text off the sheet" do
      bulk_action = create_bulk_action!()
      [row, _pending] = rows(bulk_action.id)

      error = Ash.Error.to_ash_error(RuntimeError.exception("SELECT a.lsid FROM cf.application"))
      Ash.update!(row, %{error: error}, action: :mark_failed, authorize?: false)

      Gettext.put_locale("ar")
      on_exit(fn -> Gettext.put_locale("en") end)

      [_header | [[_id, last_error | _cells] | _rest]] = decode(bulk_action)

      assert last_error == "حدث خطأ غير متوقع في هذا الصف، ولم يُحفظ شيء له."
    end
  end

  describe "object_key/1" do
    test "keys the sheet under the bulk action's staging prefix so the orphan sweep reclaims it" do
      bulk_action = create_bulk_action!()

      assert ErrorsSheet.object_key(bulk_action) ==
               "bulk-staging/#{bulk_action.user_id}/#{bulk_action.id}/errors_sheet.csv"
    end
  end
end
