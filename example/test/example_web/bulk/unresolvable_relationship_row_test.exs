defmodule ExampleWeb.Bulk.UnresolvableRelationshipRowTest do
  @moduledoc """
  What a bulk action does with a row whose **relationship lookup** cannot be
  resolved — the CSV names a related record that does not exist.

  The regression this pins: an unresolvable relationship card invalidates the
  per-row changeset *before* `for_update` stamps the action. A bare
  `Ash.update(changeset)` then fell back to the resource's primary update
  action and raised "Required primary update action" — uncaught — crashing the
  worker and stranding the bulk action at `:running`. The row must fail on its own and
  the bulk action must reach a terminal state.

  Driven over `Branch.:update` and its `:region` card. The first
  test is the control: the identical bulk action with a resolvable region
  applies every row exactly once.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.Branch
  alias Example.Test.Region

  require Ash.Query

  # Region codes and branch names are globally unique, so every
  # value a test inserts is suffixed to keep async runs off the same
  # unique-index key.
  defp uniq, do: System.unique_integer([:positive])

  defp run_region_bulk_action(conn, super_user, file_path) do
    conn
    |> login_as(super_user)
    |> visit(~p"/bulk")
    |> select_change("Resource", option: "Branch")
    |> select_change("Action", option: "Update")
    |> within("#main_form", &select_change(&1, "Lookup by", option: "Name"))
    |> within("#main_form", fn session ->
      session
      |> assert_has("input[name='sheet']", timeout: 100)
      |> upload("input[name='sheet']", "File", file_path)
      |> check("Apply all rows or none")
    end)
    |> within("#field__region", fn s ->
      s
      |> select_change("Lookup by", option: "Code")
      |> select_change("CSV column", option: "region_code")
    end)
    |> click_button("Submit")
    |> assert_has("#bulk-action-panel", timeout: 2000)
  end

  defp last_bulk_action do
    Example.BulkActions.BulkAction
    |> Ash.read!(authorize?: false)
    |> List.last()
  end

  defp create_region!(actor) do
    n = uniq()

    Ash.create!(
      Region,
      %{code: "BULKREGION#{n}", name: "Bulk Region #{n}", native_name: "منطقة #{n}"},
      actor: actor
    )
  end

  defp create_branch!(region, actor) do
    Ash.create!(Branch, %{name: "Branch #{uniq()}", region_id: region.id}, actor: actor)
  end

  test "a resolvable region applies every row exactly once", %{
    conn: conn,
    super_user: super_user,
    default_region: home
  } do
    destination = create_region!(super_user)
    branch = create_branch!(home, super_user)

    {:ok, file_path} = Briefly.create(extname: ".csv")

    File.write!(file_path, """
    name,region_code
    #{branch.name},#{destination.code}
    """)

    run_region_bulk_action(conn, super_user, file_path)

    assert %{failure: 0} = AshBulkDurable.Core.Worker.drain()

    updated =
      Branch
      |> Ash.Query.filter(name == ^branch.name)
      |> Ash.read_one!(actor: super_user)

    assert updated.region_id == destination.id
    # A double-apply would bump the version a second time.
    assert updated.version == branch.version + 1
    assert last_bulk_action().status == :completed
  end

  test "an unresolvable region fails the row, not the worker", %{
    conn: conn,
    super_user: super_user,
    default_region: home
  } do
    branch = create_branch!(home, super_user)

    {:ok, file_path} = Briefly.create(extname: ".csv")

    File.write!(file_path, """
    name,region_code
    #{branch.name},NO-SUCH-REGION-#{uniq()}
    """)

    run_region_bulk_action(conn, super_user, file_path)

    # The worker completes the job (no uncaught raise) and the bulk action lands
    # terminal with the row error surfaced — not stranded at `:running`.
    assert %{failure: 0} = AshBulkDurable.Core.Worker.drain()
    assert last_bulk_action().status == :failed

    unchanged =
      Branch
      |> Ash.Query.filter(name == ^branch.name)
      |> Ash.read_one!(actor: super_user)

    assert unchanged.region_id == branch.region_id
    assert unchanged.version == branch.version
  end
end
