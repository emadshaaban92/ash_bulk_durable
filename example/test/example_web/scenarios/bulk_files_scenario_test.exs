defmodule ExampleWeb.Scenarios.BulkFilesScenarioTest do
  @moduledoc """
  A catalogue's products get their photos by sheet: a file column names files
  in a ZIP uploaded beside it, on a bulk create and a bulk update, on the real
  `/bulk` with the real worker and `Example.BulkActions.FileResolver`. A sweep
  takes a kept file from the store while its row waits for a correction.

  `async: false`: the resources `/bulk` offers and the staging store are
  application-wide. The browser's PUT of the ZIP is stood in for by
  `Example.Test.TestStorage`.
  """
  use ExampleWeb.ConnCase, async: false

  import Example.Test.StorageHelpers
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias AshBulkDurable.Core.{PurgeStaleStaging, Worker}
  alias Example.BulkActions.BulkAction
  alias Example.Test.{SlowStorage, TestStorage}

  require Ash.Query

  @moduletag :scenario

  @file_unread "A file uploaded with this bulk action couldn&#39;t be read, so nothing was saved for this row."

  setup do
    put_storage(TestStorage)
    start_supervised!(TestStorage)

    Example.Test.StorageHelpers.put_bulk_config(:resources, [
      Example.Test.Product | ExampleWeb.Bulk.config(:resources)
    ])
  end

  test "a corrected sheet extracts again the photo swept while its row waited, and keeps the one that wasn't",
       %{conn: conn, super_user: user} do
    swept = sku()
    held = sku()
    half_swept = sku()

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    choose(view, "create")

    bulk_action =
      submit(view, user, """
      sku,stock,photos
      #{swept},-1,front.pdf
      #{held},-2,back.pdf
      #{half_swept},-3,front.pdf|back.pdf
      """)

    assert drain_finished(bulk_action).status == :completed_with_errors

    [[swept_key], [held_key], [half_key, half_kept]] = kept_files(bulk_action)

    sweep(swept_key)
    sweep(half_key)

    sheet =
      bulk_action
      |> errors_sheet()
      |> String.replace(~r/,-1\b/, ",7")
      |> String.replace(~r/,-2\b/, ",8")
      |> String.replace(~r/,-3\b/, ",9")

    upload_correction(view, sheet)
    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
    assert drain_finished(bulk_action).status == :completed

    assert %{stock: 7, photos: [extracted]} = product(swept)
    assert stored(extracted) == "front.pdf"
    refute extracted == swept_key

    assert %{stock: 8, photos: [^held_key]} = product(held)
    assert stored(held_key) == "back.pdf"

    # A value is one field's files, kept or extracted whole, in the cell's order.
    assert %{stock: 9, photos: [front, back]} = product(half_swept)
    assert stored(front) == "front.pdf"
    assert stored(back) == "back.pdf"
    assert MapSet.disjoint?(MapSet.new([front, back]), MapSet.new([half_key, half_kept]))
  end

  test "a corrected sheet keeps the file a row extracted, and a corrected file name extracts anew",
       %{conn: conn, super_user: user} do
    kept = sku()
    moved = sku()

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    choose(view, "create")

    # Both extract their file, then fail at the write on the stock.
    bulk_action =
      submit(view, user, "sku,stock,photos\n#{kept},-1,front.pdf\n#{moved},-2,front.pdf\n")

    assert drain_finished(bulk_action).status == :completed_with_errors
    [[extracted], [_other]] = kept_files(bulk_action)

    sheet =
      bulk_action
      |> errors_sheet()
      |> String.replace(~r/,-1\b/, ",7")
      |> String.replace(~r/front\.pdf,#{moved}/, "back.pdf,#{moved}")
      |> String.replace(~r/,-2\b/, ",8")

    assert sheet =~ "back.pdf"

    upload_correction(view, sheet)
    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
    assert drain_finished(bulk_action).status == :completed

    assert %{photos: [^extracted]} = product(kept)
    assert %{photos: [key]} = product(moved)
    assert stored(key) == "back.pdf"
    refute key == extracted
  end

  test "a photo too slow to store fails its row alone, on a bulk update, and the row retries",
       %{conn: conn, super_user: user} do
    slowly_stored()
    quick = product!()
    slow = product!()

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    choose(view, "update", "sku")

    bulk_action =
      submit(view, user, "sku,stock,photos\n#{quick.sku},3,front.pdf\n#{slow.sku},4,slow.pdf\n")

    log =
      capture_log(fn -> assert drain_finished(bulk_action).status == :completed_with_errors end)

    assert log =~ "took longer than 300ms to resolve"

    assert %{stock: 3, photos: [quick_photo]} = product(quick.sku)
    assert stored(quick_photo) == "front.pdf"
    assert %{stock: 1, photos: []} = product(slow.sku)

    assert render(view) =~ "This row took too long to prepare, so nothing was saved for it."
    assert errors_sheet(bulk_action) =~ "took too long to prepare"

    # The link recovers.
    put_config(:row_resolve_timeout, :timer.seconds(5))
    retry(view, bulk_action)

    assert drain_finished(bulk_action).status == :completed
    assert %{stock: 4, photos: [slow_photo]} = product(slow.sku)
    assert stored(slow_photo) == "slow.pdf"
  end

  test "all or nothing stops at the photo too slow to store, naming its row, and nothing is written",
       %{conn: conn, super_user: user} do
    slowly_stored()
    quick = product!()
    slow = product!()

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    choose(view, "update", "sku")

    bulk_action =
      submit(
        view,
        user,
        "sku,stock,photos\n#{quick.sku},3,front.pdf\n#{slow.sku},4,slow.pdf\n",
        %{"all_or_nothing" => "on"}
      )

    assert drain_finished(bulk_action).status == :failed

    html = render(view)
    assert html =~ "Row 2:"
    assert html =~ "took too long to prepare"
    assert %{stock: 1, photos: []} = product(quick.sku)
    assert %{stock: 1, photos: []} = product(slow.sku)
  end

  test "a failed bulk action retries after its ZIP was swept while no row needs the ZIP, and says so when one does",
       %{conn: conn, super_user: user} do
    held = product!()
    swept = product!()

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    choose(view, "update", "sku")

    bulk_action =
      submit(
        view,
        user,
        "sku,stock,photos\n#{held.sku},-1,front.pdf\n#{swept.sku},-2,back.pdf\n",
        %{"all_or_nothing" => "on"}
      )

    assert drain_finished(bulk_action).status == :failed
    [[held_key], [swept_key]] = kept_files(bulk_action)

    # A day after it failed, the staging sweep takes a failed bulk action's ZIP.
    sweep_staging(bulk_action)

    # A row whose file went too has nothing left to extract it from.
    sweep(swept_key)
    retry(view, bulk_action)

    assert %{status: :failed, result: %{"reason" => "staged_file_download_error"}} =
             drain_finished(bulk_action)

    # That row's new sheet names no file, so nothing needs the ZIP.
    retry(view, bulk_action, drop_file: swept.sku)

    assert drain_finished(bulk_action).status == :completed
    assert %{stock: 7, photos: [^held_key]} = product(held.sku)
    assert %{stock: 8, photos: []} = product(swept.sku)
  end

  test "a per-row bulk action that can't read its ZIP fails the rows needing it, and runs the rest",
       %{conn: conn, super_user: user} do
    with_file = sku()
    without_file = sku()

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    choose(view, "create")

    bulk_action =
      submit(view, user, """
      sku,stock,photos
      #{with_file},-1,front.pdf
      #{without_file},3,
      """)

    # The ZIP goes before the worker reads it.
    Enum.each(bulk_action.staged_files, fn {_name, key} -> TestStorage.delete_file(key, []) end)

    assert capture_log(fn ->
             assert %{status: :completed_with_errors, rows_done: 1} =
                      drain_finished(bulk_action)
           end) =~ "couldn't read its staged files"

    html = render(view)
    assert html =~ "1 of 2 rows done"
    assert html =~ @file_unread
    assert errors_sheet(bulk_action) =~ String.replace(@file_unread, "&#39;", "'")

    assert %{stock: 3} = product(without_file)
    refute product(with_file)

    # Still gone: the retry says so again, on the row.
    retry(view, bulk_action)

    assert %{status: :completed_with_errors, rows_done: 1} = drain_finished(bulk_action)
    assert render(view) =~ @file_unread

    # A row naming no file needs no ZIP.
    upload_correction(
      view,
      bulk_action |> errors_sheet() |> String.replace(",front.pdf,", ",,")
    )

    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()

    assert %{status: :completed, rows_done: 2} = drain_finished(bulk_action)
    assert %{stock: 7, photos: []} = product(with_file)
  end

  test "an all-or-nothing bulk action that can't read its ZIP stops whole",
       %{conn: conn, super_user: user} do
    with_file = sku()
    without_file = sku()

    {:ok, view, _html} = conn |> login_as(user) |> live(~p"/bulk")
    choose(view, "create")

    bulk_action =
      submit(
        view,
        user,
        "sku,stock,photos\n#{with_file},1,front.pdf\n#{without_file},3,\n",
        %{"all_or_nothing" => "on"}
      )

    Enum.each(bulk_action.staged_files, fn {_name, key} -> TestStorage.delete_file(key, []) end)

    assert %{status: :failed, result: %{"reason" => "staged_file_download_error"}} =
             drain_finished(bulk_action)

    assert render(view) =~ "A companion file couldn&#39;t be downloaded from storage."
    refute product(without_file)
  end

  defp sku, do: "SKU#{System.unique_integer([:positive])}"

  defp product! do
    Ash.create!(Example.Test.Product, %{sku: sku(), stock: 1})
  end

  defp slowly_stored do
    put_config(:row_resolve_timeout, 300)
    put_storage(SlowStorage)
  end

  defp choose(view, action, identity \\ nil) do
    view
    |> element("#main_form select[name=resource_name]")
    |> render_change(%{"_target" => ["resource_name"], "resource_name" => "product"})

    view
    |> element("#main_form select[name=action_name]")
    |> render_change(%{"_target" => ["action_name"], "action_name" => action})

    if identity do
      view
      |> element("#main_form select[name=identity_name]")
      |> render_change(%{"identity_name" => identity})
    end
  end

  defp submit(view, user, csv, form_params \\ %{}) do
    view
    |> file_input("#main_form", :sheet, [%{name: "sheet.csv", content: csv, type: "text/csv"}])
    |> render_upload("sheet.csv")

    view
    |> file_input("#field__photos", :companion__photos, [
      %{name: "photos.zip", content: zip(), type: "application/zip"}
    ])
    |> render_upload("photos.zip")

    view |> form("#main_form", form_params) |> render_submit()
    render_async(view, 2000)

    bulk_action =
      BulkAction
      |> Ash.Query.for_read(:fetch_for_user_unresolved, %{user_id: user.id})
      |> Ash.read_one!(authorize?: false)

    # The browser's PUT to the presigned URL.
    Enum.each(bulk_action.staged_files, fn {_name, key} -> TestStorage.put(key, zip()) end)
    bulk_action
  end

  defp zip do
    {:ok, path} = Briefly.create(extname: ".zip")
    File.rm!(path)

    {:ok, _} =
      :zip.create(String.to_charlist(path), [
        {~c"front.pdf", "front.pdf"},
        {~c"back.pdf", "back.pdf"},
        {~c"slow.pdf", "slow.pdf"}
      ])

    File.read!(path)
  end

  defp upload_correction(view, csv) do
    view
    |> file_input("#retry-upload-form", :retry_csv, [
      %{name: "corrections.csv", content: csv, type: "text/csv"}
    ])
    |> render_upload("corrections.csv")
  end

  defp retry(view, bulk_action, opts \\ []) do
    sheet =
      bulk_action
      |> errors_sheet()
      |> String.replace(~r/,-1\b/, ",7")
      |> String.replace(~r/,-2\b/, ",8")
      |> drop_file(opts[:drop_file])

    upload_correction(view, sheet)
    view |> element("#bulk-action-panel button", "Retry failed rows") |> render_click()
  end

  defp drop_file(sheet, nil), do: sheet
  defp drop_file(sheet, sku), do: String.replace(sheet, "back.pdf,#{sku}", ",#{sku}")

  defp sweep_staging(bulk_action) do
    long_ago = DateTime.add(DateTime.utc_now(), -25, :hour)

    # The sweep keeps a :failed bulk action's files for a day after it failed.
    Example.Repo.query!("UPDATE bulk_actions SET finished_at = $1 WHERE id = $2", [
      long_ago,
      Ecto.UUID.dump!(bulk_action.id)
    ])

    Enum.each(bulk_action.staged_files, fn {_name, key} ->
      TestStorage.put(key, zip(), long_ago)
    end)

    assert :ok = PurgeStaleStaging.sweep()
    refute Enum.any?(TestStorage.keys(), &String.starts_with?(&1, "bulk-staging/"))
  end

  defp errors_sheet(bulk_action) do
    bulk_action |> ExampleWeb.Bulk.ErrorsSheet.build() |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp kept_files(bulk_action) do
    bulk_action
    |> AshBulkDurable.Core.open_rows()
    |> Enum.map(& &1.resolved_data["photos"])
  end

  defp drain_finished(bulk_action) do
    Worker.drain()
    Ash.get!(BulkAction, bulk_action.id, authorize?: false)
  end

  defp product(sku) do
    Example.Test.Product
    |> Ash.Query.filter(sku == ^sku)
    |> Ash.read_one!(authorize?: false)
  end

  # The fixture's bytes are the name of the file they came from.
  defp stored(key) do
    {:ok, body} = TestStorage.get_object(key)
    body
  end

  # A day on, a sweep takes what no record references.
  defp sweep(key), do: :ok = TestStorage.delete_file(key, [])
end
