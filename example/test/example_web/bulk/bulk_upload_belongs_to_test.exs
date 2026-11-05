defmodule ExampleWeb.Bulk.BulkUploadBelongsToTest do
  @moduledoc """
  A `/bulk` row whose required `belongs_to` is left unmapped
  (`AshBulkDurable.Sheet.FieldHandlers.BelongsTo`): a book's `:author`, whose
  `allow_nil?: false` rejects every row in the worker.

  Driven through the durable bulk action flow: click Submit, then drain the queue.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Library.Book

  test "rows whose required belongs_to is left unmapped fail in the worker",
       %{conn: conn, super_user: super_user} do
    isbn = "ISBN#{System.unique_integer([:positive])}"

    {:ok, file_path} = Briefly.create(extname: ".csv")

    File.write!(file_path, """
    isbn,title
    #{isbn},Unwritten
    """)

    session =
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Book")
      |> select_change("Action", option: "Create")
      |> within("#main_form", &upload(&1, "input[name='sheet']", "File", file_path))
      |> within("#field__isbn", &select_change(&1, "CSV column", option: "isbn"))
      |> within("#field__title", &select_change(&1, "CSV column", option: "title"))
      # `:author` is left unmapped, so the bulk action reaches the worker but
      # every row lands :failed and the bulk action ends :completed_with_errors.
      |> click_button("Submit")
      |> assert_has("#bulk-action-panel", timeout: 2000)

    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    session
    |> assert_has("h2, h3, p, div", text: "Completed with errors")
    |> assert_has("button", text: "Download errors sheet")
    |> assert_has("button", text: "Abandon failed rows")

    # And no book was committed.
    assert Book |> Ash.Query.filter(isbn == ^isbn) |> Ash.read!(authorize?: false) == []
  end
end
