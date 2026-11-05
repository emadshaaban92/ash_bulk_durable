defmodule AshBulkDurable.PrimaryKeyTest do
  @moduledoc """
  A resource's primary key need not be an `id`: rows over a key of another
  name, or of several attributes, run through the facade and the worker and
  each row records the key of the record it wrote. No resource in the app has
  either shape, so `/bulk` cannot reach them.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Test.{BulkAction, Row}
  alias AshBulkDurable.Test.{Plate, Seat}

  setup %{super_user: user}, do: %{scope: AshBulkDurable.Test.Scope.new(actor: user)}

  defp run!(bulk_action) do
    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    rows =
      Row
      |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
      |> Ash.Query.sort(row_index: :asc)
      |> Ash.read!(authorize?: false)

    {Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending]),
     rows}
  end

  defp plate(number), do: Ash.get(Plate, number, authorize?: false)

  defp seat(hall, number),
    do: Ash.get(Seat, %{hall: hall, number: number}, authorize?: false)

  test "a key not named id: created, updated and destroyed, each row naming its record", %{
    scope: scope
  } do
    first = System.unique_integer([:positive])
    second = System.unique_integer([:positive])

    {:ok, created} =
      AshBulkDurable.bulk_create(
        [%{number: first, name: "first"}, %{number: second, name: "second"}],
        Plate,
        :create,
        scope: scope
      )

    {created, rows} = run!(created)
    assert created.status == :completed

    assert Enum.map(rows, &{&1.status, &1.record_id}) ==
             [{:succeeded, to_string(first)}, {:succeeded, to_string(second)}]

    {:ok, updated} =
      AshBulkDurable.update_many([{first, %{name: "renamed"}}], Plate, :update, scope: scope)

    {updated, [row]} = run!(updated)
    assert updated.status == :completed
    assert row.record_id == to_string(first)
    assert {:ok, %{name: "renamed"}} = plate(first)

    {:ok, destroyed} =
      AshBulkDurable.destroy_many([{second, %{}}], Plate, :destroy, scope: scope)

    {destroyed, [row]} = run!(destroyed)
    assert destroyed.status == :completed
    assert row.record_id == to_string(second)
    assert {:error, _not_found} = plate(second)
    assert {:ok, _kept} = plate(first)
  end

  test "a composite key: a row records every part, and the parts can't run together", %{
    scope: scope
  } do
    # A hall holding the separator is what a joined string would get wrong.
    hall = "A&B=#{System.unique_integer([:positive])}"

    {:ok, created} =
      AshBulkDurable.bulk_create(
        [%{hall: hall, number: 1, name: "one"}, %{hall: hall, number: 2, name: "two"}],
        Seat,
        :create,
        scope: scope
      )

    {created, [one, two]} = run!(created)
    assert created.status == :completed
    assert {one.status, two.status} == {:succeeded, :succeeded}
    assert URI.decode_query(one.record_id) == %{"hall" => hall, "number" => "1"}
    assert URI.decode_query(two.record_id) == %{"hall" => hall, "number" => "2"}

    # One target by its keys, one as the record itself: both reach a row's lookup.
    {:ok, record} = seat(hall, 2)

    {:ok, updated} =
      AshBulkDurable.update_many(
        [{%{hall: hall, number: 1}, %{name: "uno"}}, {record, %{name: "dos"}}],
        Seat,
        :update,
        scope: scope
      )

    {updated, rows} = run!(updated)
    assert updated.status == :completed
    assert Enum.map(rows, & &1.record_id) == [one.record_id, two.record_id]
    assert {:ok, %{name: "uno"}} = seat(hall, 1)
    assert {:ok, %{name: "dos"}} = seat(hall, 2)

    {:ok, destroyed} =
      AshBulkDurable.destroy_many([{%{hall: hall, number: 1}, %{}}], Seat, :destroy, scope: scope)

    {destroyed, [row]} = run!(destroyed)
    assert destroyed.status == :completed
    assert row.record_id == one.record_id
    assert {:error, _not_found} = seat(hall, 1)
    assert {:ok, _kept} = seat(hall, 2)
  end

  test "one row failing on a key not named id fails that row, its neighbours written", %{
    scope: scope
  } do
    missing = System.unique_integer([:positive])
    present = System.unique_integer([:positive])
    Ash.create!(Plate, %{number: present, name: "before"}, authorize?: false)

    {:ok, bulk_action} =
      AshBulkDurable.update_many(
        [{missing, %{name: "lost"}}, {present, %{name: "after"}}],
        Plate,
        :update,
        scope: scope
      )

    {bulk_action, [lost, kept]} = run!(bulk_action)
    assert bulk_action.status == :completed_with_errors
    assert lost.status == :failed
    assert lost.record_id == nil
    assert kept.status == :succeeded
    assert kept.record_id == to_string(present)
    assert {:ok, %{name: "after"}} = plate(present)
  end
end
