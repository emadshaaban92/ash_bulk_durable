defmodule ExampleWeb.Scenarios.BulkArabicErrorsScenarioTest do
  @moduledoc """
  A bulk action's refusals read in the reader's language wherever `/bulk`
  shows them: the failed rows under the run, the errors sheet they download, and
  the reason a run applying all rows or none was rolled back.

  The worker writes each refusal in no reader's language, so it keeps what to
  word it with and the page words it when it is read. The errors sheet is built
  in a task, which inherits no locale, so it is read back here as it was
  uploaded.

  `async: false`: the sheet is read from `Example.Test.TestStorage`, which
  replaces the application-wide storage adapter for the test.
  """
  use ExampleWeb.FeatureCase, async: false

  import Example.Test.StorageHelpers
  import ExampleWeb.FeatureCase, only: [select_change: 3]

  require Ash.Query

  alias ExampleWeb.Bulk.ErrorsSheet
  alias Example.BulkActions.BulkAction
  alias Example.Accounts.User
  alias Example.Test.RoleTestHelpers

  @moduletag :scenario

  setup do
    put_storage(Example.Test.TestStorage)
    start_supervised!(Example.Test.TestStorage)
    :ok
  end

  test "an Arabic reader reads why each row failed, on the page and in the sheet",
       %{conn: conn, super_user: super_user} do
    admin =
      super_user
      |> RoleTestHelpers.create_user_with_platform_role(:platform_admin)
      |> arabic()

    n = :erlang.unique_integer([:positive])

    # One region with no name: Ash's own refusal, against the field it names.
    csv = """
    code,name,native
    AR#{n},Named #{n},اسم #{n}
    AR-NONAME-#{n},,بلا اسم #{n}
    """

    conn
    |> login_as(admin)
    |> run_in_arabic(csv)
    |> assert_has("td", text: "الاسم: مطلوب")
    |> refute_has("td", text: "is required")
    |> click_button("تنزيل ملف الأخطاء")
    |> assert_has("a", text: "تنزيل", timeout: 2000)

    sheet = sheet_of(admin)
    assert sheet =~ "الاسم: مطلوب"
    refute sheet =~ "is required"

    # The same refusal, with every row or none applied: the run rolls back and
    # says which row stopped it.
    conn
    |> login_as(admin)
    |> visit(~p"/bulk")
    |> click_button("استبعاد الصفوف التي فشل تنفيذها")
    |> run_in_arabic(
      """
      code,name,native
      AR-ATOMIC-#{n},,ذري #{n}
      """,
      all_or_nothing: true
    )
    |> assert_has("[role='alert']", text: "فشل صف، فأُلغي الإجراء المجمّع بالكامل")
    |> assert_has("[role='alert']", text: "الصف 1: الاسم: مطلوب")
    |> refute_has("[role='alert']", text: "is required")
  end

  test "an Arabic reader reads that a row's code matched nothing, updating or deleting",
       %{conn: conn, super_user: super_user} do
    admin = arabic(super_user)
    missing = "MISSING#{:erlang.unique_integer([:positive])}"

    conn
    |> login_as(admin)
    |> visit(~p"/bulk")
    |> run_on_regions("تعديل", "code,name\n#{missing},Renamed\n")
    |> assert_has("td", text: "الكود: غير موجود")
    |> refute_has("td", text: "not_found")
    |> refute_has("td", text: "could not be found")
    |> click_button("استبعاد الصفوف التي فشل تنفيذها")
    |> visit(~p"/bulk")
    |> run_on_regions("حذف", "code\n#{missing}\n")
    |> assert_has("td", text: "الكود: غير موجود")
    |> refute_has("td", text: "not_found")
    |> refute_has("td", text: "could not be found")
  end

  # Updates or deletes regions found by code, leaving the outcome to the
  # caller.
  test "a lookup matching nothing reads in Arabic, naming what was looked up",
       %{conn: conn, super_user: super_user} do
    reader = arabic(super_user)
    missing = "NOREGION#{System.unique_integer([:positive])}"
    branch = "فرع #{System.unique_integer([:positive])}"

    {:ok, file_path} = Briefly.create(extname: ".csv")
    File.write!(file_path, "name,region\n#{branch},#{missing}\n")

    conn
    |> login_as(reader)
    |> visit(~p"/bulk?resource=branch&action=create")
    |> within("#main_form", &upload(&1, "input[name='sheet']", "الملف", file_path))
    |> within("#field__name", &select_change(&1, "عمود CSV", option: "name"))
    |> within("#field__region", fn session ->
      session
      |> select_change("البحث بـ", option: "الكود")
      |> select_change("عمود CSV", option: "region")
    end)
    |> click_button("إرسال")
    |> assert_has("#bulk-action-panel", timeout: 2000)
    |> tap(fn _session ->
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
    end)
    |> assert_has("td", text: "المنطقة: لا توجد نتيجة في المنطقة تطابق الكود = \"#{missing}\"")
    |> refute_has("td", text: "matches")
  end

  defp run_on_regions(session, action, csv) do
    {:ok, file_path} = Briefly.create(extname: ".csv")
    File.write!(file_path, csv)

    session =
      session
      |> select_change("نوع البيانات", option: "المنطقة")
      |> select_change("الإجراء", option: action)
      |> select_change("البحث بـ", option: "الكود")
      |> within("#main_form", &upload(&1, "input[name='sheet']", "الملف", file_path))

    session =
      if csv =~ "name",
        do: within(session, "#field__name", &select_change(&1, "عمود CSV", option: "name")),
        else: session

    session =
      session
      |> click_button("إرسال")
      |> assert_has("#bulk-action-panel h2", text: "الإجراء المجمّع", timeout: 2000)

    Oban.drain_queue(queue: :bulk_actions)
    session
  end

  # Leaves the outcome to the caller: here rows are meant to fail.
  defp run_in_arabic(session, csv, opts \\ []) do
    {:ok, file_path} = Briefly.create(extname: ".csv")
    File.write!(file_path, csv)

    session =
      session
      |> visit(~p"/bulk")
      |> assert_has("h3", text: "تعليمات الإجراءات المجمّعة")
      |> select_change("نوع البيانات", option: "المنطقة")
      |> select_change("الإجراء", option: "إنشاء")
      |> within("#main_form", &upload(&1, "input[name='sheet']", "الملف", file_path))
      |> within("#field__code", &select_change(&1, "عمود CSV", option: "code"))
      |> within("#field__name", &select_change(&1, "عمود CSV", option: "name"))
      |> within("#field__native_name", &select_change(&1, "عمود CSV", option: "native"))

    session =
      if opts[:all_or_nothing], do: check(session, "تطبيق كل الصفوف أو لا شيء"), else: session

    session =
      session
      |> click_button("إرسال")
      |> assert_has("#bulk-action-panel h2", text: "الإجراء المجمّع", timeout: 2000)

    Oban.drain_queue(queue: :bulk_actions)
    session
  end

  # The sheet the reader's Download link points at, as it was uploaded.
  defp sheet_of(user) do
    run =
      BulkAction
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read_one!(authorize?: false)

    {:ok, sheet} = run |> ErrorsSheet.object_key() |> Example.Test.TestStorage.get_object()
    sheet
  end

  defp arabic(user) do
    User
    |> Ash.get!(user.id, authorize?: false)
    |> Ash.update!(%{locale: :ar}, action: :update_profile, actor: user, authorize?: false)
  end
end
