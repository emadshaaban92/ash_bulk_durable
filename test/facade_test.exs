defmodule AshBulkDurable.FacadeTest do
  @moduledoc """
  `AshBulkDurable`'s verbs as a script calls them: a list of inputs or a
  sheet read from a file, queued as a bulk action the worker then runs.
  The example's `/bulk` page reaches the same verbs with a sheet; these prove the inputs a script holds, and the refusals a screen never
  sends.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Test.{Book, Shelf}
  alias AshBulkDurable.Test.{BulkAction, Row}
  alias AshBulkDurable.Test.Branch
  alias AshBulkDurable.Test.{Region, User}
  alias AshBulkDurable.Test.RoleTestHelpers

  setup %{super_user: user} do
    %{user: user, scope: AshBulkDurable.Test.Scope.new(actor: user)}
  end

  defp region_inputs(count) do
    tag = "F#{System.unique_integer([:positive])}"

    Enum.map(1..count, fn n ->
      %{code: "#{tag}#{n}", name: "Region #{tag}#{n}", native_name: "منطقة #{tag}#{n}"}
    end)
  end

  defp create_regions!(count, user) do
    count
    |> region_inputs()
    |> Enum.map(&Ash.create!(Region, &1, actor: user))
  end

  defp create_branches!(count, user) do
    Enum.map(1..count, fn _n ->
      Ash.create!(Branch, %{name: "Branch #{System.unique_integer([:positive])}"}, actor: user)
    end)
  end

  defp reloaded(records, user),
    do: Enum.map(records, &Ash.reload!(&1, actor: user, authorize?: false))

  defp region_ids(branches, user),
    do: branches |> reloaded(user) |> Enum.map(& &1.region_id)

  defp exists?(branch, user),
    do: match?({:ok, _branch}, Ash.reload(branch, actor: user, authorize?: false))

  defp run!(bulk_action) do
    assert bulk_action.status == :queued
    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    {Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending]),
     rows(bulk_action)}
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp regions(codes) do
    Region
    |> Ash.Query.filter(code in ^codes)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.code, &1})
  end

  defp write_file!(name, content) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "bulk_create/4 with inputs" do
    test "creates a record per input", %{scope: scope} do
      inputs = region_inputs(3)

      assert {:ok, bulk_action} =
               AshBulkDurable.bulk_create(inputs, Region, :create, scope: scope)

      {bulk_action, rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.rows_done == 3
      assert Enum.map(rows, & &1.status) == [:succeeded, :succeeded, :succeeded]
      assert inputs |> Enum.map(& &1.code) |> regions() |> map_size() == 3
    end

    test "per row, a refused input fails alone and keeps its error", %{scope: scope} do
      [first, second] = region_inputs(2)
      # The second reuses the first's code, a unique identity.
      inputs = [first, %{second | code: first.code}]

      {:ok, bulk_action} = AshBulkDurable.bulk_create(inputs, Region, :create, scope: scope)
      {bulk_action, [kept, refused]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert kept.status == :succeeded
      assert refused.status == :failed
      assert Enum.map_join(refused.error, & &1.message) =~ "has already been taken"
      assert regions([first.code])[first.code].name == first.name
    end

    test "all or nothing, a refused input writes no row", %{scope: scope} do
      [first, second] = region_inputs(2)
      inputs = [first, %{second | code: first.code}]

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(inputs, Region, :create,
          scope: scope,
          mode: :all_or_nothing
        )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :failed
      assert bulk_action.result["row_index"] == 1
      assert regions([first.code]) == %{}
    end

    # The chunk size sizes a per-row bulk action's batches. Here it must not
    # split the one transaction, or the rows before the last would commit.
    test "all or nothing is one transaction, however small its chunk size", %{scope: scope} do
      [first, second, third] = region_inputs(3)
      inputs = [first, second, %{third | code: first.code}]

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(inputs, Region, :create,
          scope: scope,
          mode: :all_or_nothing,
          chunk_size: 2
        )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :failed
      assert bulk_action.result["row_index"] == 2
      assert regions([first.code, second.code]) == %{}
    end

    test "a verb refuses an action of another type", %{scope: scope} do
      assert_raise ArgumentError, ~r/is a update action; this verb runs create actions/, fn ->
        AshBulkDurable.bulk_create(region_inputs(1), Region, :update, scope: scope)
      end

      assert_raise ArgumentError, ~r/has no action :nope/, fn ->
        AshBulkDurable.bulk_create([], Region, :nope, scope: scope)
      end
    end
  end

  describe "a lookup in an input" do
    test "its value may be a struct, and a miss names it", %{scope: scope} do
      shelf =
        Ash.create!(Shelf, %{code: "SHELF#{System.unique_integer([:positive])}"},
          authorize?: false
        )

      missing = "MISSING#{System.unique_integer([:positive])}"
      [found, lost] = Enum.map(1..2, fn _n -> "Title#{System.unique_integer([:positive])}" end)

      lookup = fn code -> {:lookup, Shelf, :code, Ash.CiString.new(code)} end

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(
          [
            %{title: found, shelf_id: lookup.(shelf.code)},
            %{title: lost, shelf_id: lookup.(missing)}
          ],
          Book,
          :create,
          scope: scope
        )

      {bulk_action, [written, refused]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert written.status == :succeeded
      assert [%{message: message}] = refused.error
      assert message =~ "no Shelf matches code = #Ash.CiString"
      assert message =~ missing

      assert [%{"shelf_id" => ^missing}] = AshBulkDurable.errors_sheet(bulk_action).rows
    end
  end

  describe "a selection that cannot be read" do
    test "a query on an action that cannot stream is an error, not a raise", %{scope: scope} do
      query = Ash.Query.for_read(Region, :by_code, %{code: "X"}, scope: scope)

      assert {:error, %Ash.Error.Invalid.NonStreamableAction{}} =
               AshBulkDurable.bulk_update(query, :update, %{name: "x"}, scope: scope)
    end
  end

  describe "update_many/4 with targets" do
    test "finds a target by identity, by record or by primary key", %{user: user, scope: scope} do
      [by_code, by_string_key, by_record, by_key] = create_regions!(4, user)

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [
            {%{code: by_code.code}, %{name: "#{by_code.code} by code"}},
            {%{"code" => by_string_key.code}, %{"name" => "#{by_string_key.code} by string"}}
          ],
          Region,
          :update,
          identity: :code,
          scope: scope
        )

      {bulk_action, _rows} = run!(bulk_action)
      assert bulk_action.status == :completed

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [
            {by_record, %{name: "#{by_record.code} by record"}},
            {by_key.id, %{name: "#{by_key.code} by key"}}
          ],
          Region,
          :update,
          scope: scope
        )

      {bulk_action, rows} = run!(bulk_action)
      assert bulk_action.status == :completed
      assert Enum.map(rows, & &1.record_id) == [by_record.id, by_key.id]

      updated = regions(Enum.map([by_code, by_string_key, by_record, by_key], & &1.code))

      assert updated[by_code.code].name == "#{by_code.code} by code"
      assert updated[by_string_key.code].name == "#{by_string_key.code} by string"
      assert updated[by_record.code].name == "#{by_record.code} by record"
      assert updated[by_key.code].name == "#{by_key.code} by key"
    end

    # A struct is one value, never a map of a composite identity's keys.
    test "a target's value may be a struct, and one matching nothing still reads on its row and sheet",
         %{user: user, scope: scope} do
      organization = RoleTestHelpers.create_organization(user)

      person =
        RoleTestHelpers.create_user_with_organization_role(user, organization, [:clerk])

      missing = Ash.CiString.new("missing#{System.unique_integer([:positive])}@example.com")

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [{%{email: person.email}, %{}}, {%{email: missing}, %{}}],
          User,
          :update,
          identity: :email,
          scope: scope
        )

      {bulk_action, [found, gone]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert found.record_id == person.id
      assert [%{error: %Ash.Error.Query.NotFound{primary_key: %{email: ^missing}}}] = gone.error

      sheet = AshBulkDurable.errors_sheet(bulk_action)
      assert [%{"email" => cell}] = sheet.rows
      assert cell == to_string(missing)

      # The sheet corrects it like any other key.
      corrected = Enum.map(sheet.rows, &Map.put(&1, "email", to_string(person.email)))

      {:ok, retried} = AshBulkDurable.retry(bulk_action, %{sheet | rows: corrected}, scope: scope)
      assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()
      assert Ash.reload!(retried, authorize?: false).status == :completed
    end

    test "a target matching nothing fails its row", %{user: user, scope: scope} do
      [found] = create_regions!(1, user)
      missing = "MISSING#{System.unique_integer([:positive])}"

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [
            {%{code: found.code}, %{name: "#{found.code} found"}},
            {%{code: missing}, %{name: "x"}}
          ],
          Region,
          :update,
          identity: :code,
          scope: scope
        )

      {bulk_action, [_found, lost]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert lost.status == :failed
      assert Enum.map_join(lost.error, & &1.message) =~ missing
      assert regions([found.code])[found.code].name == "#{found.code} found"
    end

    test "a sheet with no :identity is refused, nothing naming the record each row means",
         %{user: user, scope: scope} do
      [branch] = create_branches!(1, user)
      sheet = %AshBulkDurable.Sheet{headers: ["name"], rows: [%{"name" => "Renamed"}]}

      assert_raise ArgumentError, ~r/needs an :identity/, fn ->
        AshBulkDurable.update_many(sheet, Branch, :update, scope: scope)
      end

      assert_raise ArgumentError, ~r/needs an :identity/, fn ->
        AshBulkDurable.destroy_many(sheet, Branch, :destroy, scope: scope)
      end

      assert %{success: 0} = AshBulkDurable.Core.Worker.drain()
      assert exists?(branch, user)
      refute hd(reloaded([branch], user)).name == "Renamed"
    end

    test "a target missing a key of its identity is refused before anything is written",
         %{scope: scope} do
      assert_raise ArgumentError, ~r/has no :code/, fn ->
        AshBulkDurable.update_many([{%{name: "x"}, %{}}], Region, :update,
          identity: :code,
          scope: scope
        )
      end

      assert_raise ArgumentError, ~r/has no identity :nope/, fn ->
        AshBulkDurable.update_many([], Region, :update, identity: :nope, scope: scope)
      end

      assert BulkAction |> Ash.read!(authorize?: false) |> Enum.empty?()
    end

    test "a partial identity is refused: its keys don't name one record", %{scope: scope} do
      assert_raise ArgumentError, ~r/has no identity :order that names one record/, fn ->
        AshBulkDurable.update_many([], AshBulkDurable.Test.Booking, :refresh,
          identity: :order,
          scope: scope
        )
      end
    end
  end

  describe "destroy_many/4 with targets" do
    test "destroys each target found by identity", %{user: user, scope: scope} do
      [gone, kept] = create_regions!(2, user)

      {:ok, bulk_action} =
        AshBulkDurable.destroy_many([{%{code: gone.code}, %{}}], Region, :destroy,
          identity: :code,
          scope: scope
        )

      {bulk_action, [row]} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert row.record_id == gone.id
      assert Map.keys(regions([gone.code, kept.code])) == [kept.code]
    end
  end

  describe "bulk_update/4 over a selection" do
    setup %{user: user} do
      [region] = create_regions!(1, user)
      %{region: region}
    end

    test "over IDs, one input is stored once and every row runs with it",
         %{user: user, scope: scope, region: region} do
      [first, second] = branches = create_branches!(2, user)
      shared = %{region_id: region.id}

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([first.id, second.id], :update, shared,
          resource: Branch,
          scope: scope
        )

      {bulk_action, rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.action_type == :update
      assert bulk_action.input == shared
      assert Enum.map(rows, & &1.input) == [nil, nil]
      assert Enum.map(rows, & &1.record_id) == [first.id, second.id]
      assert region_ids(branches, user) == [region.id, region.id]
    end

    test "records know their resource", %{user: user, scope: scope, region: region} do
      branches = create_branches!(2, user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(branches, :update, %{region_id: region.id}, scope: scope)

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.resource_name == inspect(Branch)
      assert region_ids(branches, user) == [region.id, region.id]
    end

    test "a query selects what it matches, whatever the page its read action would stop at",
         %{user: user, scope: scope, region: region} do
      # One past the :index action's default_limit.
      selected = create_branches!(21, user)
      [left_alone] = create_branches!(1, user)
      selected_ids = Enum.map(selected, & &1.id)

      {:ok, bulk_action} =
        Branch
        |> Ash.Query.for_read(:index, %{}, scope: scope)
        |> Ash.Query.filter(id in ^selected_ids)
        |> AshBulkDurable.bulk_update(:update, %{region_id: region.id}, scope: scope)

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.total_rows == 21
      assert selected |> region_ids(user) |> Enum.uniq() == [region.id]
      assert region_ids([left_alone], user) == [nil]
    end

    test "a query is read as the caller, so a row is only what they could see", ctx do
      organization = RoleTestHelpers.create_organization(ctx.user)
      other_organization = RoleTestHelpers.create_organization(ctx.user)

      admin =
        RoleTestHelpers.create_user_with_organization_role(ctx.user, organization, [:admin])

      colleague =
        RoleTestHelpers.create_user_with_organization_role(ctx.user, organization, [
          :clerk
        ])

      stranger =
        RoleTestHelpers.create_user_with_organization_role(ctx.user, other_organization, [
          :clerk
        ])

      ids = [colleague.id, stranger.id]

      {:ok, bulk_action} =
        User
        |> Ash.Query.filter(id in ^ids)
        |> AshBulkDurable.bulk_update(:update, %{},
          scope: AshBulkDurable.Test.Scope.new(actor: admin)
        )

      assert Enum.map(rows(bulk_action), & &1.target.lookup) == [%{id: colleague.id}]
    end

    test "a shared lookup resolves for each row", ctx do
      branches = create_branches!(2, ctx.user)
      shared = %{region_id: {:lookup, Region, :code, ctx.region.code}}

      {:ok, bulk_action} = AshBulkDurable.bulk_update(branches, :update, shared, scope: ctx.scope)
      assert Enum.map(rows(bulk_action), & &1.status) == [:pending, :pending]

      {bulk_action, rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert Enum.all?(rows, &(&1.input == nil))
      assert region_ids(branches, ctx.user) == [ctx.region.id, ctx.region.id]
    end

    test "a shared lookup matching nothing fails every row, naming what it looked for", ctx do
      branches = create_branches!(2, ctx.user)
      missing = "MISSING#{System.unique_integer([:positive])}"
      shared = %{region_id: {:lookup, Region, :code, missing}}

      {:ok, bulk_action} = AshBulkDurable.bulk_update(branches, :update, shared, scope: ctx.scope)
      {bulk_action, rows} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert Enum.map(rows, & &1.status) == [:failed, :failed]
      assert Enum.all?(rows, &(Enum.map_join(&1.error, fn e -> e.message end) =~ missing))
      assert region_ids(branches, ctx.user) == [nil, nil]
    end

    test "per row, a record gone by the time its row runs fails alone, and again on a retry",
         ctx do
      [kept, gone, other] = create_branches!(3, ctx.user)
      shared = %{region_id: {:lookup, Region, :code, ctx.region.code}}

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([kept, gone], :update, shared, scope: ctx.scope)

      Ash.destroy!(gone, actor: ctx.user)
      {bulk_action, [_kept, failed]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert failed.status == :failed
      assert region_ids([kept], ctx.user) == [ctx.region.id]

      # A selected record stays the one selected, so nothing moves the row on.
      {:ok, _retried} = AshBulkDurable.retry(bulk_action, scope: ctx.scope)
      assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

      bulk_action =
        Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending])

      assert bulk_action.status == :completed_with_errors
      assert Ash.reload!(failed, authorize?: false).status == :failed
      assert region_ids([other], ctx.user) == [nil]

      assert {:ok, %BulkAction{status: :cancelled}} =
               AshBulkDurable.abandon(bulk_action, scope: ctx.scope)
    end

    test "all or nothing, one refusal writes no record", ctx do
      [first, second] = create_regions!(2, ctx.user)
      shared = %{name: "Shared #{System.unique_integer([:positive])}"}

      # The name is unique: the second write of the one input is refused.
      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([first, second], :update, shared,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :failed
      assert bulk_action.result["row_index"] == 1
      assert Enum.map(reloaded([first, second], ctx.user), & &1.name) == [first.name, second.name]
    end

    test "per row, the same refusal keeps the rows that could be written", ctx do
      [first, second] = create_regions!(2, ctx.user)
      shared = %{name: "Shared #{System.unique_integer([:positive])}"}

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([first, second], :update, shared, scope: ctx.scope)

      {bulk_action, [written, refused]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert written.status == :succeeded
      assert refused.status == :failed

      assert Enum.map(reloaded([first, second], ctx.user), & &1.name) == [
               shared.name,
               second.name
             ]
    end

    test "a role that may read but not write selects, and every row is refused", ctx do
      branches = create_branches!(2, ctx.user)
      viewer = RoleTestHelpers.create_user_with_platform_role(ctx.user, :platform_viewer)

      {:ok, bulk_action} =
        Branch
        |> Ash.Query.filter(id in ^Enum.map(branches, & &1.id))
        |> AshBulkDurable.bulk_update(:update, %{region_id: ctx.region.id},
          scope: AshBulkDurable.Test.Scope.new(actor: viewer)
        )

      {bulk_action, rows} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert Enum.map(rows, & &1.status) == [:failed, :failed]
      assert region_ids(branches, ctx.user) == [nil, nil]
    end

    test "an empty selection finishes with nothing to do", %{scope: scope} do
      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([], :update, %{}, resource: Branch, scope: scope)

      {bulk_action, rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.input == nil
      assert rows == []
    end

    test "a programmer's mistake is refused before anything is written", %{scope: scope} do
      assert_raise ArgumentError, ~r/needs `:resource`/, fn ->
        AshBulkDurable.bulk_update([Ecto.UUID.generate()], :update, %{}, scope: scope)
      end

      assert_raise ArgumentError, ~r/is a create action; this verb runs update actions/, fn ->
        AshBulkDurable.bulk_update(Ash.Query.new(Branch), :create, %{}, scope: scope)
      end

      assert_raise ArgumentError, ~r/has no action :nope/, fn ->
        AshBulkDurable.bulk_update(Ash.Query.new(Branch), :nope, %{}, scope: scope)
      end

      assert_raise ArgumentError, ~r/a selection is a query or a list/, fn ->
        AshBulkDurable.bulk_update(%AshBulkDurable.Sheet{}, :update, %{},
          resource: Branch,
          scope: scope
        )
      end

      assert BulkAction |> Ash.read!(authorize?: false) |> Enum.empty?()
    end

    test "a query that cannot be read is an error, with nothing written", %{scope: scope} do
      query = Ash.Query.filter_input(Branch, %{nope: "x"})

      assert {:error, %Ash.Error.Invalid{}} =
               AshBulkDurable.bulk_update(query, :update, %{}, scope: scope)

      assert BulkAction |> Ash.read!(authorize?: false) |> Enum.empty?()
    end
  end

  describe "bulk_destroy/4 over a selection" do
    test "over IDs, with no input in either place", %{user: user, scope: scope} do
      [gone, kept] = create_branches!(2, user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_destroy([gone.id], :destroy, resource: Branch, scope: scope)

      {bulk_action, [row]} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert bulk_action.action_type == :destroy
      assert bulk_action.input == nil
      assert row.input == nil
      assert row.record_id == gone.id
      refute exists?(gone, user)
      assert exists?(kept, user)
    end

    test "over a query", %{user: user, scope: scope} do
      [gone, kept] = create_branches!(2, user)

      {:ok, bulk_action} =
        Branch
        |> Ash.Query.filter(id == ^gone.id)
        |> AshBulkDurable.bulk_destroy(:destroy, scope: scope)

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      refute exists?(gone, user)
      assert exists?(kept, user)
    end

    test "a shared input reaches the action", %{user: user, scope: scope} do
      [branch] = create_branches!(1, user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_destroy([branch], :destroy, %{nope: "x"}, scope: scope)

      {bulk_action, [row]} = run!(bulk_action)

      assert bulk_action.status == :completed_with_errors
      assert Enum.map_join(row.error, & &1.message) =~ "nope"
      assert exists?(branch, user)
    end

    test "refuses an action of another type", %{scope: scope} do
      assert_raise ArgumentError, ~r/is a update action; this verb runs destroy actions/, fn ->
        AshBulkDurable.bulk_destroy([], :update, resource: Branch, scope: scope)
      end
    end
  end

  describe "a sheet" do
    test "read_sheet/2 strips Excel's byte-order mark, and a verb runs the sheet by its mapping",
         %{user: user, scope: scope} do
      [region] = create_regions!(1, user)

      path =
        write_file!(
          "regions.csv",
          "﻿Code,Name\n#{region.code},  #{region.code} from a sheet  \n,\n"
        )

      assert {:ok, %AshBulkDurable.Sheet{} = sheet} = AshBulkDurable.read_sheet(path)
      assert sheet.headers == ["Code", "Name"]
      # Cells are trimmed; a row of blank cells is dropped.
      assert sheet.rows == [
               %{"Code" => region.code, "Name" => "#{region.code} from a sheet"}
             ]

      {:ok, bulk_action} =
        AshBulkDurable.update_many(sheet, Region, :update,
          identity: :code,
          mapping: [columns: %{code: "Code", name: "Name"}],
          scope: scope
        )

      {bulk_action, [row]} = run!(bulk_action)

      assert bulk_action.status == :completed

      assert row.metadata == %{
               "Code" => region.code,
               "Name" => "#{region.code} from a sheet"
             }

      assert regions([region.code])[region.code].name ==
               "#{region.code} from a sheet"
    end

    test "creates from a sheet as from inputs", %{scope: scope} do
      [input] = region_inputs(1)

      path =
        write_file!(
          "regions.csv",
          "code,name,native_name\n#{input.code},#{input.name},#{input.native_name}\n"
        )

      {:ok, sheet} = AshBulkDurable.read_sheet(path)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(sheet, Region, :create,
          mapping: [columns: %{code: "code", name: "name", native_name: "native_name"}],
          scope: scope
        )

      {bulk_action, _rows} = run!(bulk_action)

      assert bulk_action.status == :completed
      assert regions([input.code])[input.code].native_name == input.native_name
    end

    test "read_sheet/2 refuses a file it cannot read" do
      assert {:error, {:unknown_type, ".txt"}} =
               "notes.txt" |> write_file!("a,b\n1,2\n") |> AshBulkDurable.read_sheet()

      assert {:error, {:in2csv, _status, _output}} =
               "broken.xlsx" |> write_file!("not a workbook") |> AshBulkDurable.read_sheet()

      assert {:error, %File.Error{}} = AshBulkDurable.read_sheet("/nonexistent/sheet.csv")
    end
  end

  describe "abandon/2" do
    setup %{scope: scope} do
      [first, second] = region_inputs(2)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([first, %{second | code: first.code}], Region, :create,
          scope: scope
        )

      %{bulk_action: bulk_action}
    end

    test "refuses a queued bulk action, and one its caller does not own", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               AshBulkDurable.abandon(ctx.bulk_action, scope: ctx.scope)

      {finished, _rows} = run!(ctx.bulk_action)
      assert finished.status == :completed_with_errors

      other =
        AshBulkDurable.Test.RoleTestHelpers.create_user_with_platform_role(
          ctx.user,
          :platform_admin
        )

      other_scope = AshBulkDurable.Test.Scope.new(actor: other)

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.abandon(finished, scope: other_scope)

      assert {:ok, %BulkAction{status: :cancelled}} =
               AshBulkDurable.abandon(finished, scope: ctx.scope)

      # Final: an abandoned bulk action is not abandoned again.
      cancelled =
        Ash.get!(BulkAction, finished.id, authorize?: false, load: [:rows_done, :rows_pending])

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.abandon(cancelled, scope: ctx.scope)
    end
  end

  describe "abandon/2 after an all-or-nothing failure" do
    test "refuses one that failed outright, which holds no failed rows to give up", ctx do
      [first, second] = region_inputs(2)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([first, %{second | code: first.code}], Region, :create,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      {failed, _rows} = run!(bulk_action)
      assert failed.status == :failed

      assert {:error, %Ash.Error.Invalid{}} = AshBulkDurable.abandon(failed, scope: ctx.scope)

      assert Ash.get!(BulkAction, failed.id, authorize?: false, load: [:rows_done, :rows_pending]).status ==
               :failed
    end
  end
end
