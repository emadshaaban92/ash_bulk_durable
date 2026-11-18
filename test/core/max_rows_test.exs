defmodule AshBulkDurable.Core.MaxRowsTest do
  @moduledoc """
  `:max_rows` (`ValidateMaxRows`): a bulk action of more rows is refused at
  create, in either mode, with nothing written, and no more of a stream, a
  query selection or a sheet is read or mapped than it takes to go over.

  `async: false` — each test swaps the global `:max_rows` setting via app
  env.
  """
  use AshBulkDurable.DataCase, async: false

  alias AshBulkDurable.Core
  alias AshBulkDurable.Sheet
  alias AshBulkDurable.Test.{BulkAction, Region, Row}

  setup %{super_user: user} do
    AshBulkDurable.StorageHelpers.put_config(:max_rows, 2)
    %{user: user, scope: AshBulkDurable.Test.Scope.new(actor: user)}
  end

  defp region_inputs(count) do
    tag = "M#{System.unique_integer([:positive])}"
    Enum.map(1..count, &%{code: "#{tag}#{&1}", name: "Region #{tag}#{&1}", native_name: "N#{&1}"})
  end

  defp counts do
    {AshBulkDurable.Test.Repo.aggregate(BulkAction, :count, :id),
     AshBulkDurable.Test.Repo.aggregate(Row, :count, :id)}
  end

  defp assert_capped({:error, %Ash.Error.Invalid{errors: errors}}) do
    assert [%{field: :total_rows, message: message}] = errors
    assert message =~ "capped at 2 rows"
  end

  test "a bulk action over the cap is refused, in either mode, with nothing written",
       %{scope: scope} do
    before = counts()

    for mode <- [:per_row, :all_or_nothing] do
      assert_capped(
        AshBulkDurable.bulk_create(region_inputs(3), Region, :create, scope: scope, mode: mode)
      )
    end

    assert counts() == before
  end

  test "a bulk action at the cap is queued", %{scope: scope} do
    assert {:ok, %{status: :queued, total_rows: 2}} =
             AshBulkDurable.bulk_create(region_inputs(2), Region, :create, scope: scope)
  end

  test "a stream is read no further than it takes to go over", %{scope: scope} do
    counter = :counters.new(1, [])

    rows =
      Stream.repeatedly(fn ->
        :counters.add(counter, 1, 1)
        %{input: hd(region_inputs(1))}
      end)

    assert_capped(Core.create(Region, :create, rows, scope: scope))
    assert :counters.get(counter, 1) == 3
  end

  test "a query selection over the cap is refused", %{user: user, scope: scope} do
    regions = Enum.map(region_inputs(3), &Ash.create!(Region, &1, actor: user))
    query = Ash.Query.filter_input(Region, %{id: %{in: Enum.map(regions, & &1.id)}})

    assert_capped(AshBulkDurable.bulk_update(query, :update, %{name: "x"}, scope: scope))

    assert {:ok, %{total_rows: 2}} =
             AshBulkDurable.bulk_update(Ash.Query.limit(query, 2), :update, %{name: "x"},
               scope: scope
             )
  end

  test "a sheet over the cap is refused", %{scope: scope} do
    sheet = %Sheet{
      headers: ["code", "name"],
      rows: Enum.map(region_inputs(3), &%{"code" => &1.code, "name" => &1.name})
    }

    assert_capped(
      AshBulkDurable.bulk_create(sheet, Region, :create,
        mapping: [columns: %{code: "code", name: "name"}],
        scope: scope
      )
    )
  end
end
