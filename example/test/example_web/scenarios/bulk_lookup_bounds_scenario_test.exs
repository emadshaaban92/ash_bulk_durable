defmodule ExampleWeb.Scenarios.BulkLookupBoundsScenarioTest do
  @moduledoc """
  What a `/bulk` sheet may reach. A relationship column finds only what the
  relationship allows and the reader may read, and a blank cell of a
  composite lookup means an empty column. An action reads the mode it runs
  in. this app has no filtered relationship, so `Example.Test.Volume`
  stands in, on the real page and worker.

  `async: false` because `/bulk`'s offered resources are global config.
  """
  use ExampleWeb.FeatureCase, async: false

  alias Example.Test.{Volume, Shelf, Vault}
  alias Example.Test.RoleTestHelpers

  @moduletag :scenario

  setup %{super_user: super_user} do
    Example.Test.StorageHelpers.put_bulk_config(:resources, [
      Volume | ExampleWeb.Bulk.config(:resources)
    ])

    organization = RoleTestHelpers.create_organization(super_user)

    officer = fn ->
      RoleTestHelpers.create_user_with_organization_role(super_user, organization, [
        :clerk
      ])
    end

    {:ok, officer: officer}
  end

  test "a sheet links only a shelf the relationship's filter allows", %{
    conn: conn,
    super_user: super_user
  } do
    open = shelf()
    closed = shelf(open: false)
    linked = title()

    conn
    |> login_as(super_user)
    |> submit_volumes("title,shelf\n#{linked},#{open.code}\n#{title()},#{closed.code}\n", :shelf)
    |> drain()
    |> assert_has("*", text: "1 of 2 rows done")
    |> assert_has("td", text: "no result in Shelf matches Code = \"#{closed.code}\"")

    assert [%{shelf_id: shelf_id}] = volumes()[linked]
    assert shelf_id == open.id
  end

  test "a sheet finds a shelf only for the person who may read it, whoever asks", %{
    conn: conn,
    officer: officer
  } do
    [first, second] = [officer.(), officer.()]
    [firsts, seconds] = Enum.map([first, second], &shelf(owner_id: &1.id))
    [one, other] = [title(), title()]

    conn
    |> login_as(first)
    |> submit_volumes("title,shelf\n#{one},#{firsts.code}\n#{title()},#{seconds.code}\n", :shelf)
    |> drain()
    |> assert_has("*", text: "1 of 2 rows done")
    |> assert_has("td", text: "no result in Shelf matches Code = \"#{seconds.code}\"")

    conn
    |> login_as(second)
    |> submit_volumes(
      "title,shelf\n#{other},#{seconds.code}\n#{title()},#{firsts.code}\n",
      :shelf
    )
    |> drain()
    |> assert_has("*", text: "1 of 2 rows done")
    |> assert_has("td", text: "no result in Shelf matches Code = \"#{firsts.code}\"")

    assert [%{shelf_id: shelf_id}] = volumes()[one]
    assert shelf_id == firsts.id
    assert [%{shelf_id: shelf_id}] = volumes()[other]
    assert shelf_id == seconds.id
  end

  test "a read the reader is refused fails the row with the refusal, and the row beside it writes",
       %{conn: conn, super_user: super_user, officer: officer} do
    vault = Ash.create!(Vault, %{code: code("VAULT")}, authorize?: false)
    [refused, allowed] = [title(), title()]

    conn
    |> login_as(officer.())
    |> submit_volumes("title,vault\n#{refused},#{vault.code}\n", :vault)
    |> drain()
    |> assert_has("*", text: "0 of 1 rows done")
    |> assert_has("td", text: "forbidden")

    conn
    |> login_as(super_user)
    |> submit_volumes("title,vault\n#{allowed},#{vault.code}\n", :vault)
    |> drain()
    |> assert_has("*", text: "1 of 1 rows done")

    refute volumes()[refused]
    assert [%{vault_id: vault_id}] = volumes()[allowed]
    assert vault_id == vault.id
  end

  test "a blank cell of a composite lookup finds the shelf with no bay, not one that has a bay",
       %{conn: conn, super_user: super_user} do
    aisle = code("AISLE")
    no_bay = shelf(aisle: aisle)
    _with_a_bay = shelf(aisle: aisle, bay: "B")
    placed = title()

    conn
    |> login_as(super_user)
    |> visit_volumes("title,aisle,bay\n#{placed},#{aisle},\n")
    |> within("#field__shelf", fn session ->
      session
      |> select_change("Lookup by", option: "Place")
      |> select_change("Aisle", option: "aisle")
      |> select_change("Bay", option: "bay")
    end)
    |> click_button("Submit")
    |> assert_has("#bulk-action-panel", timeout: 2000)
    |> drain()
    |> assert_has("*", text: "1 of 1 rows done")

    assert [%{shelf_id: shelf_id}] = volumes()[placed]
    assert shelf_id == no_bay.id
  end

  test "a lookup by an identity named unlike its key finds by that key", %{
    conn: conn,
    super_user: super_user
  } do
    marked = shelf(serial: code("MARK"))
    linked = title()

    conn
    |> login_as(super_user)
    |> visit_volumes("title,mark\n#{linked},#{marked.serial}\n")
    |> within("#field__shelf", fn session ->
      session
      |> select_change("Lookup by", option: "Shelf mark")
      |> select_change("CSV column", option: "mark")
    end)
    |> click_button("Submit")
    |> assert_has("#bulk-action-panel", timeout: 2000)
    |> drain()
    |> assert_has("*", text: "1 of 1 rows done")

    assert [%{shelf_id: shelf_id}] = volumes()[linked]
    assert shelf_id == marked.id
  end

  test "an action needing all or nothing is refused per row, and runs when asked for it", %{
    conn: conn,
    super_user: super_user,
    officer: officer
  } do
    whole = title()

    conn
    |> login_as(officer.())
    |> submit_catalogue("title\n#{title()}\n")
    |> drain()
    |> assert_has("td", text: "a catalogue goes in whole or not at all")

    conn
    |> login_as(super_user)
    |> submit_catalogue("title\n#{whole}\n", all_or_nothing: true)
    |> drain()
    |> assert_has("*", text: "1 of 1 rows done")

    assert volumes()[whole]
  end

  defp submit_volumes(session, csv, relationship) do
    session
    |> visit_volumes(csv)
    |> within("#field__#{relationship}", fn session ->
      session
      |> select_change("Lookup by", option: "Code")
      |> select_change("CSV column", option: to_string(relationship))
    end)
    |> click_button("Submit")
    |> assert_has("#bulk-action-panel", timeout: 2000)
  end

  defp visit_volumes(session, csv) do
    session
    |> visit(~p"/bulk")
    |> select_change("Resource", option: "Volume")
    |> select_change("Action", option: "Create")
    |> within("#main_form", &upload(&1, "input[name='sheet']", "File", sheet(csv)))
    |> within("#field__title", &select_change(&1, "CSV column", option: "title"))
  end

  defp submit_catalogue(session, csv, opts \\ []) do
    session =
      session
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "Volume")
      |> select_change("Action", option: "Catalogue")
      |> within("#main_form", &upload(&1, "input[name='sheet']", "File", sheet(csv)))
      |> within("#field__title", &select_change(&1, "CSV column", option: "title"))

    session =
      if opts[:all_or_nothing], do: check(session, "Apply all rows or none"), else: session

    session
    |> click_button("Submit")
    |> assert_has("#bulk-action-panel", timeout: 2000)
  end

  defp sheet(csv) do
    {:ok, file_path} = Briefly.create(extname: ".csv")
    File.write!(file_path, csv)
    file_path
  end

  defp drain(session) do
    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()
    session
  end

  defp shelf(attrs \\ []) do
    Ash.create!(Shelf, Map.new([{:code, code("SHELF")} | attrs]), authorize?: false)
  end

  defp volumes, do: Volume |> Ash.read!(authorize?: false) |> Enum.group_by(& &1.title)

  defp title, do: code("Title")
  defp code(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"
end
