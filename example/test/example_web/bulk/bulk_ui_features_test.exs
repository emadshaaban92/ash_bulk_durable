defmodule ExampleWeb.Bulk.BulkUIFeaturesTest do
  use ExampleWeb.FeatureCase, async: true

  # Region code/name/native_name are all globally unique — keep every row's values
  # unique per test so concurrent async tests never contend on the same key.
  defp test_csv_content do
    i = System.unique_integer([:positive])

    """
    code,name,native_name
    UITEST#{i}A,UI Test Region #{i} A,اختبار واجهة #{i} أ
    UITEST#{i}B,UI Test Region #{i} B,اختبار واجهة #{i} ب
    UITEST#{i}C,UI Test Region #{i} C,اختبار واجهة #{i} ج
    """
  end

  describe "Upload Instructions" do
    test "shows upload instructions when resource is selected but no file uploaded", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> assert_has("h3", text: "Bulk Action Instructions")
      |> select_change("Resource", option: "Region")
      |> assert_has("h3", text: "Bulk Action Instructions")
      |> select_change("Action", option: "Create")
      |> assert_has("h3", text: "Bulk Action Instructions")
    end

    test "hides upload instructions after file is uploaded", %{
      conn: conn,
      super_user: super_user
    } do
      {:ok, file_path} = Briefly.create(extname: ".csv")
      File.write!(file_path, test_csv_content())

      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      # Instructions visible before upload
      |> assert_has("h3", text: "Bulk Action Instructions")
      |> within("#main_form", fn session ->
        session
        |> assert_has("input[name='sheet']", timeout: 100)
        |> upload("input[name='sheet']", "File", file_path)
      end)
      # Instructions hidden after upload
      |> refute_has("h3", text: "Bulk Action Instructions")
      # Table should now be visible
      |> assert_has("table")
    end
  end

  describe "Data Summary" do
    test "shows data summary with file info and success status when no errors", %{
      conn: conn,
      super_user: super_user
    } do
      {:ok, file_path} = Briefly.create(extname: ".csv")
      File.write!(file_path, test_csv_content())

      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      |> within("#main_form", fn session ->
        session
        |> assert_has("input[name='sheet']", timeout: 100)
        |> upload("input[name='sheet']", "File", file_path)
      end)
      # Wait for file processing and check data summary appears
      |> assert_has("table")
      |> assert_has("strong", text: "File:")
      |> assert_has("*", text: "3 rows uploaded")
      # Success status
      |> assert_has("div.badge-success", text: "Ready to submit")
      # Success icon should be present
      |> assert_has("svg")
    end

    test "does not show data summary when no file is uploaded", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      |> refute_has("strong", text: "File:")
      |> refute_has("div.badge-success", text: "Ready to submit")
      |> refute_has("div.badge-error", text: "errors found")
    end
  end

  describe "Responsive Design" do
    test "form uses responsive grid layout", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      # Check that the main form has responsive grid classes
      |> assert_has("form[class*='lg:grid'][class*='lg:grid-cols-5']")
      |> assert_has("form[class*='space-y-4'][class*='lg:space-y-0']")
    end

    test "table maintains unique form field IDs", %{
      conn: conn,
      super_user: super_user
    } do
      {:ok, file_path} = Briefly.create(extname: ".csv")
      File.write!(file_path, test_csv_content())

      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      |> within("#main_form", fn session ->
        session
        |> assert_has("input[name='sheet']", timeout: 100)
        |> upload("input[name='sheet']", "File", file_path)
      end)
      # Verify that we don't have duplicate IDs (this would cause LiveView errors)
      |> assert_has("select[id='mapping__code']", count: 1)
      |> assert_has("select[id='mapping__name']", count: 1)
      |> assert_has("select[id='mapping__native_name']", count: 1)
    end
  end

  describe "UI State Management" do
    test "table previews fields once resource/action are picked, and instructions hide on upload",
         %{conn: conn, super_user: super_user} do
      {:ok, file_path} = Briefly.create(extname: ".csv")
      File.write!(file_path, test_csv_content())

      # First state: instructions and empty table both visible (so the user sees field shape upfront)
      session =
        conn
        |> login_as(super_user)
        |> visit(~p"/bulk")
        |> select_change("Resource", option: "Region")
        |> select_change("Action", option: "Create")
        |> assert_has("h3", text: "Bulk Action Instructions")
        |> assert_has("table")

      # Second state: after upload, instructions hide and table is populated
      session
      |> within("#main_form", fn session ->
        session
        |> assert_has("input[name='sheet']", timeout: 100)
        |> upload("input[name='sheet']", "File", file_path)
      end)
      |> refute_has("h3", text: "Bulk Action Instructions")
      |> assert_has("table")
    end
  end

  describe "Smart Messaging Logic" do
    test "shows initial instructions when no resource selected", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> assert_has("h3", text: "Bulk Action Instructions")
      |> assert_has("p", text: "Start by selecting a resource and action above")
    end

    test "prompts for action when resource selected but no action", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> assert_has("h3", text: "Bulk Action Instructions")
      |> assert_has("p", text: "Select an action above to continue")
    end

    test "prompts for identity when non-create action selected but no identity", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Update")
      |> assert_has("h3", text: "Bulk Action Instructions")
      |> assert_has("p", text: "Select a lookup field above to identify existing records")
    end
  end

  describe "File Input Visibility Logic" do
    test "hides file input when no resource selected", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> refute_has("input[name='sheet']")
    end

    test "hides file input when resource selected but no action", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> refute_has("input[name='sheet']")
    end

    test "shows file input for create action (no identity required)", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      |> assert_has("input[name='sheet']")
    end

    test "hides file input for non-create action without identity", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Update")
      |> refute_has("input[name='sheet']")
    end

    test "shows file input for non-create action with identity selected", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      # Booking, because it refreshes: a non-create action beyond update.
      |> select_change("Resource", option: "Booking")
      |> select_change("Action", option: "Refresh")
      |> within("#main_form", &select_change(&1, "Lookup by", option: "Primary key"))
      |> assert_has("input[name='sheet']")
    end

    test "file input toggles correctly when cycling through action types", %{
      conn: conn,
      super_user: super_user
    } do
      session =
        conn
        |> login_as(super_user)
        |> visit(~p"/bulk")
        |> select_change("Resource", option: "Region")

      session
      |> select_change("Action", option: "Update")
      |> refute_has("input[name='sheet']")
      |> within("#main_form", &select_change(&1, "Lookup by", option: "Name"))
      |> assert_has("input[name='sheet']")
      |> select_change("Action", option: "Destroy")
      |> refute_has("input[name='sheet']")
      |> within("#main_form", &select_change(&1, "Lookup by", option: "Code"))
      |> assert_has("input[name='sheet']")
      |> select_change("Action", option: "Update")
      |> refute_has("input[name='sheet']")
      |> within("#main_form", &select_change(&1, "Lookup by", option: "Name"))
      |> assert_has("input[name='sheet']")
    end
  end

  describe "Uploaded File Pill" do
    test "replaces file input with a filename pill and a clear button after upload", %{
      conn: conn,
      super_user: super_user
    } do
      {:ok, file_path} = Briefly.create(extname: ".csv")
      File.write!(file_path, test_csv_content())

      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      |> within("#main_form", fn session ->
        session
        |> assert_has("input[name='sheet']", timeout: 100)
        |> upload("input[name='sheet']", "File", file_path)
      end)
      |> refute_has("input[name='sheet']")
      |> assert_has("button[phx-click='clear_upload']")
      |> assert_has("span", text: Path.basename(file_path))
    end

    test "deselecting the action after upload restores instructions but keeps the file", %{
      conn: conn,
      super_user: super_user
    } do
      {:ok, file_path} = Briefly.create(extname: ".csv")
      File.write!(file_path, test_csv_content())

      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      |> within("#main_form", fn session ->
        session
        |> assert_has("input[name='sheet']", timeout: 100)
        |> upload("input[name='sheet']", "File", file_path)
      end)
      |> refute_has("h3", text: "Bulk Action Instructions")
      |> select_change("Action", option: "")
      # Page reverts to a not-ready state: instructions return, table hides, data summary hides…
      |> assert_has("h3", text: "Bulk Action Instructions")
      |> refute_has("table")
      |> refute_has("strong", text: "File:")
      # …but the file pill remains, so the user knows their upload is preserved.
      |> assert_has("button[phx-click='clear_upload']")
      # Re-selecting the action brings the table and data summary back without re-uploading.
      |> select_change("Action", option: "Create")
      |> assert_has("table")
      |> assert_has("strong", text: "File:")
    end

    test "mapping persists across action changes when fields still apply", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(
        "/bulk?resource=region&action=create&mapping%5Bcode%5D=code&mapping%5Bname%5D=name"
      )
      |> assert_has("table")
      |> select_change("Action", option: "Update")
      |> assert_path("/bulk",
        query_params: %{
          "resource" => "region",
          "action" => "update",
          "mapping" => %{"code" => "code", "name" => "name"}
        }
      )
    end

    test "clear button removes the uploaded file and re-shows the file input", %{
      conn: conn,
      super_user: super_user
    } do
      {:ok, file_path} = Briefly.create(extname: ".csv")
      File.write!(file_path, test_csv_content())

      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Region")
      |> select_change("Action", option: "Create")
      |> within("#main_form", fn session ->
        session
        |> assert_has("input[name='sheet']", timeout: 100)
        |> upload("input[name='sheet']", "File", file_path)
      end)
      |> assert_has("button[phx-click='clear_upload']")
      |> click_button("✕")
      |> assert_has("input[name='sheet']")
      |> refute_has("button[phx-click='clear_upload']")
      |> refute_has("strong", text: "File:")
      |> assert_has("h3", text: "Bulk Action Instructions")
    end
  end

  describe "Required vs Optional badges" do
    test "on :create, attributes with allow_nil?: false render the Required badge", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk?resource=region&action=create")
      |> within("#field__name", fn s -> s |> assert_has(".badge", text: "Required") end)
      |> within("#field__native_name", fn s -> s |> assert_has(".badge", text: "Required") end)
      |> within("#field__code", fn s -> s |> assert_has(".badge", text: "Required") end)
    end

    test "on :update, non-identity attributes flip to Optional even when allow_nil?: false", %{
      conn: conn,
      super_user: super_user
    } do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk?resource=region&action=update&identity=code")
      # `code` is the identity key — still required.
      |> within("#field__code", fn s -> s |> assert_has(".badge", text: "Required") end)
      # `name` and `native_name` would be required on create but are
      # optional on update — the existing row already has them.
      |> within("#field__name", fn s -> s |> assert_has(".badge", text: "Optional") end)
      |> within("#field__native_name", fn s -> s |> assert_has(".badge", text: "Optional") end)
    end

    test "switching action from :create to :update demotes non-identity required fields",
         %{conn: conn, super_user: super_user} do
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk?resource=region&action=create")
      |> within("#field__name", fn s -> s |> assert_has(".badge", text: "Required") end)
      |> select_change("Action", option: "Update")
      |> within("#main_form", &select_change(&1, "Lookup by", option: "Code"))
      |> within("#field__name", fn s -> s |> assert_has(".badge", text: "Optional") end)
    end
  end
end
