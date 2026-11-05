defmodule ExampleWeb.Scenarios.BulkReferencesScenarioTest do
  @moduledoc """
  A sheet's relationship column names the related record by an identity; the
  bulk action looks it up before it writes anything, and keeps what it found
  on the row. Branches by sheet, each naming its region by code:
  one per row, one all or nothing, and one resumed after the worker stopped
  between looking up and writing.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.BulkActions.{BulkAction, Row}

  @moduletag :scenario

  setup %{super_user: super_user} do
    %{region: create_default_region(super_user)}
  end

  test "per row, a branch whose region is found is written naming it, and one whose code matches nothing fails saying so",
       %{conn: conn, super_user: super_user, region: region} do
    found = branch_name()
    missing = "NOREGION#{System.unique_integer([:positive])}"

    conn
    |> login_as(super_user)
    |> submit_branches("""
    name,region
    #{found},#{region.code}
    #{branch_name()},#{missing}
    """)
    |> drain()
    |> assert_has("*", text: "1 of 2 rows done")
    |> assert_has("td",
      text: "Region: no result in Region matches Code = \"#{missing}\""
    )

    assert region_name(found, super_user) == region.name
  end

  test "all or nothing, a code that matches nothing stops the bulk action before any branch is written",
       %{conn: conn, super_user: super_user, region: region} do
    found = branch_name()
    missing = "NOREGION#{System.unique_integer([:positive])}"

    conn
    |> login_as(super_user)
    |> submit_branches(
      """
      name,region
      #{found},#{region.code}
      #{branch_name()},#{missing}
      """,
      all_or_nothing: true
    )
    |> drain()
    |> assert_has("[role='alert']",
      text: "A row failed, so the bulk action stopped before any rows were written."
    )
    |> assert_has("[role='alert']", text: "Row 2: Region: no result in Region matches")

    assert branch_id(found, super_user) == nil
  end

  # The worker keeps what a lookup found on the row before it writes, so one
  # that stopped in between writes what it found then, even once the code it
  # looked up by names nothing.
  test "resumed after stopping between looking up and writing, a branch names the region found before",
       %{conn: conn, super_user: super_user, region: region} do
    other = create_default_region(super_user)
    first = branch_name()
    second = branch_name()

    session =
      conn
      |> login_as(super_user)
      |> submit_branches("""
      name,region
      #{first},#{region.code}
      #{second},#{other.code}
      """)

    # The first row was looked up when the worker stopped, the second not yet.
    [looked_up, _pending] = rows_of(super_user)

    Ash.Seed.update!(looked_up, %{
      resolved_data: %{"region_id" => region.id},
      status: :resolved
    })

    # The code it was found by now names nothing.
    Ash.update!(region, %{code: "MOVED#{System.unique_integer([:positive])}"}, actor: super_user)

    session
    |> drain()
    |> assert_has("*", text: "2 of 2 rows done")

    assert region_name(first, super_user) == region.name
    assert region_name(second, super_user) == other.name
  end

  defp submit_branches(session, csv, opts \\ []) do
    {:ok, file_path} = Briefly.create(extname: ".csv")
    File.write!(file_path, csv)

    session =
      session
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Branch")
      |> select_change("Action", option: "Create")
      |> within("#main_form", &upload(&1, "input[name='sheet']", "File", file_path))
      |> within("#field__name", &select_change(&1, "CSV column", option: "name"))
      |> within("#field__region", fn s ->
        s
        |> select_change("Lookup by", option: "Code")
        |> select_change("CSV column", option: "region")
      end)

    session =
      if opts[:all_or_nothing], do: check(session, "Apply all rows or none"), else: session

    session
    |> click_button("Submit")
    |> assert_has("#bulk-action-panel", timeout: 2000)
  end

  defp drain(session) do
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
    session
  end

  defp rows_of(user) do
    bulk_action =
      BulkAction
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read_one!(authorize?: false)

    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp branch(name, actor) do
    Example.Test.Branch
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.load(:region)
    |> Ash.read_one!(actor: actor)
  end

  defp branch_id(name, actor) do
    case branch(name, actor) do
      nil -> nil
      branch -> branch.id
    end
  end

  defp region_name(name, actor), do: branch(name, actor).region.name

  defp branch_name, do: "فرع #{System.unique_integer([:positive])}"
end
