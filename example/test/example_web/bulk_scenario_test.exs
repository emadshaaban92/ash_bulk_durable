defmodule ExampleWeb.BulkScenarioTest do
  @moduledoc """
  `/bulk` end to end on this app: a sheet uploaded on the page, the bulk action
  run by the real worker, and what the reader sees of it.
  """
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshBulkDurable.Core.Worker
  alias Example.Accounts.User
  alias Example.BulkActions.{BulkAction, LocalStorage}
  alias Example.Library.{Author, Book}

  require Ash.Query

  setup %{conn: conn} do
    tag = System.unique_integer([:positive])

    user =
      Ash.create!(User, %{name: "Ada", email: "ada#{tag}@example.test"}, authorize?: false)

    author =
      Ash.create!(Author, %{name: "Ursula", email: "ursula#{tag}@example.test"},
        authorize?: false
      )

    %{conn: init_test_session(conn, user_id: user.id), user: user, author: author, tag: tag}
  end

  defp isbn(tag, n), do: "#{tag}-#{n}"

  defp book(isbn) do
    Book |> Ash.Query.filter(isbn == ^isbn) |> Ash.read_one!(authorize?: false)
  end

  defp choose(view, resource, action) do
    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => resource})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => action})
  end

  defp identify_by(view, identity) do
    view
    |> element("#main_form select[name=identity_name]")
    |> render_change(%{"identity_name" => identity})
  end

  defp author_by_email(view) do
    view
    |> element("select[name=rel_identities__author]")
    |> render_change(%{
      "_target" => ["rel_identities__author"],
      "rel_identities__author" => "email"
    })
  end

  defp upload(view, csv) do
    view
    |> file_input("#main_form", :sheet, [%{name: "sheet.csv", content: csv, type: "text/csv"}])
    |> render_upload("sheet.csv")
  end

  defp submit(view, form_params \\ %{}) do
    view |> form("#main_form", form_params) |> render_submit()
    render_async(view, 2000)
  end

  defp finish(view, user) do
    Worker.drain()
    _ = :sys.get_state(view.pid)
    render(view)
    latest(user)
  end

  defp latest(user) do
    BulkAction
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.Query.sort(id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp zip(files) do
    {:ok, path} = Briefly.create(extname: ".zip")
    File.rm!(path)

    {:ok, _} =
      :zip.create(String.to_charlist(path), Enum.map(files, fn {n, b} -> {~c"#{n}", b} end))

    File.read!(path)
  end

  defp put_presigned(conn, key, body) do
    url = LocalStorage.presigned_put_url(key, content_length: byte_size(body))

    conn
    |> recycle()
    |> put_req_header("content-type", "application/zip")
    |> put(url, body)
  end

  test "a sheet of books creates them, finding each author by email", %{conn: conn} = context do
    {:ok, view, _html} = live(conn, ~p"/bulk")
    choose(view, "book", "create")

    upload(view, """
    isbn,title,pages,author
    #{isbn(context.tag, 1)},The Dispossessed,387,#{context.author.email}
    #{isbn(context.tag, 2)},Lavinia,288,#{context.author.email}
    """)

    author_by_email(view)
    submit(view)

    assert %{status: :completed, rows_done: 2, mode: :per_row} = finish(view, context.user)
    assert render(view) =~ "2 of 2 rows done"
    assert book(isbn(context.tag, 1)).title == "The Dispossessed"

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Lavinia"
  end

  test "a sheet updates and destroys records found by an identity", %{conn: conn} = context do
    for n <- 1..2 do
      Ash.create!(
        Book,
        %{isbn: isbn(context.tag, n), title: "Old", author_id: context.author.id},
        authorize?: false
      )
    end

    {:ok, view, _html} = live(conn, ~p"/bulk")
    choose(view, "book", "update")
    identify_by(view, "isbn")

    upload(view, """
    isbn,title
    #{isbn(context.tag, 1)},New
    """)

    submit(view)
    assert %{status: :completed} = finish(view, context.user)
    assert book(isbn(context.tag, 1)).title == "New"
    assert book(isbn(context.tag, 2)).title == "Old"

    view |> element("#bulk-action-panel button", "Dismiss") |> render_click()

    view |> element("button[aria-label='Clear file']") |> render_click()
    choose(view, "book", "destroy")
    identify_by(view, "isbn")
    upload(view, "isbn\n#{isbn(context.tag, 2)}\n")
    submit(view)

    assert %{status: :completed} = finish(view, context.user)
    assert book(isbn(context.tag, 2)) == nil
    assert book(isbn(context.tag, 1))
  end

  test "all-or-nothing writes nothing when one row fails", %{conn: conn} = context do
    {:ok, view, _html} = live(conn, ~p"/bulk")
    choose(view, "book", "create")

    upload(view, """
    isbn,title,pages,author
    #{isbn(context.tag, 1)},Fine,100,#{context.author.email}
    #{isbn(context.tag, 2)},Refused,0,#{context.author.email}
    """)

    author_by_email(view)
    submit(view, %{"all_or_nothing" => "on"})

    assert %{status: :failed, mode: :all_or_nothing} = finish(view, context.user)
    assert book(isbn(context.tag, 1)) == nil
    assert render(view) =~ "Pages: must be greater than 0"
  end

  test "a failed row keeps its error, and its corrected sheet retries only it",
       %{conn: conn} = context do
    {:ok, view, _html} = live(conn, ~p"/bulk")
    choose(view, "book", "create")

    upload(view, """
    isbn,title,pages,author
    #{isbn(context.tag, 1)},Fine,100,#{context.author.email}
    #{isbn(context.tag, 2)},Refused,0,#{context.author.email}
    """)

    author_by_email(view)
    submit(view)

    assert %{status: :completed_with_errors} = bulk_action = finish(view, context.user)
    assert render(view) =~ "Pages: must be greater than 0"
    assert book(isbn(context.tag, 1))

    # The reload finds the parked bulk action.
    {:ok, view, _html} = live(conn, ~p"/bulk")
    assert render(view) =~ "Pages: must be greater than 0"

    view |> element("#bulk-action-panel button", "Download errors sheet") |> render_click()
    html = render_async(view, 2000)
    [_, href] = Regex.run(~r{href="(/storage/[^"]+)"}, html)
    csv = conn |> recycle() |> get(href) |> response(200)
    assert csv =~ "Pages: must be greater than 0"

    corrected = String.replace(csv, ",0,", ",50,")

    view
    |> file_input("#retry-upload-form", :retry_csv, [
      %{name: "corrections.csv", content: corrected, type: "text/csv"}
    ])
    |> render_upload("corrections.csv")

    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()

    assert %{status: :completed, rows_done: 2} = finish(view, context.user)
    assert bulk_action.id == latest(context.user).id
    assert book(isbn(context.tag, 2)).pages == 50
  end

  test "a cover named in the sheet comes out of the companion ZIP", %{conn: conn} = context do
    {:ok, view, _html} = live(conn, ~p"/bulk")
    choose(view, "book", "create")

    upload(view, """
    isbn,title,cover,author
    #{isbn(context.tag, 1)},With cover,front.png,#{context.author.email}
    #{isbn(context.tag, 2)},Missing cover,nope.png,#{context.author.email}
    """)

    author_by_email(view)
    archive = zip([{"front.png", "the-cover"}])

    view
    |> file_input("#field__cover", :companion__cover, [
      %{name: "covers.zip", content: archive, type: "application/zip"}
    ])
    |> render_upload("covers.zip")

    submit(view)

    bulk_action = latest(context.user)
    assert [{"cover", key}] = Map.to_list(bulk_action.staged_files)
    assert conn |> put_presigned(key, archive) |> response(200)

    assert %{status: :completed_with_errors} = finish(view, context.user)

    written = book(isbn(context.tag, 1))
    assert {:ok, "the-cover"} = File.read(LocalStorage.path(written.cover))
    assert render(view) =~ "no file named"
  end

  test "a bulk action is its owner's alone", %{conn: conn} = context do
    {:ok, view, _html} = live(conn, ~p"/bulk")
    choose(view, "author", "create")
    upload(view, "name,email\nOctavia,o#{context.tag}@example.test\n")
    submit(view)
    assert %{status: :completed} = bulk_action = finish(view, context.user)

    stranger =
      Ash.create!(User, %{name: "Grace", email: "grace#{context.tag}@example.test"},
        authorize?: false
      )

    conn = build_conn() |> init_test_session(user_id: stranger.id)
    {:ok, view, _html} = live(conn, ~p"/bulk?bulk_action=#{bulk_action.id}")
    refute render(view) =~ "1 of 1 rows done"
  end

  test "a signed storage URL can't be used for anything else", %{conn: conn} do
    get_url = LocalStorage.presigned_get_url("bulk-staging/x/secret.csv", [])

    assert conn
           |> put_req_header("content-type", "text/csv")
           |> put(get_url, "body")
           |> response(403)

    assert conn |> recycle() |> get("/storage/forged") |> response(403)
  end
end
