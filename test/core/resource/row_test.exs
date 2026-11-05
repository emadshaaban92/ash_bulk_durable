defmodule AshBulkDurable.Core.Resource.RowTest do
  @moduledoc """
  Action smoke tests for `AshBulkDurable.Core.Resource.Row` — the row-level
  read actions and the per-row status flips. Exercises the framework
  extension through a shell resource (`AshBulkDurable.Test.Row`).
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Test.{BulkAction, Row}

  defp create_bulk_action!(rows, shared_input \\ nil) do
    Ash.create!(
      BulkAction,
      %{
        input: shared_input,
        user_id: Ecto.UUID.generate(),
        resource_name: "AshBulkDurable.Test.Asset",
        action_name: :create,
        action_type: :create,
        total_rows: length(rows),
        mode: :per_row,
        chunk_size: 50,
        rows: rows
      },
      action: :create,
      authorize?: false
    )
  end

  # A row whose input holds a reference waits for the resolve phase; one
  # holding none is born resolved.
  defp pending(i),
    do: %{input: %{name: {:lookup, AshBulkDurable.Test.Region, :code, "C#{i}"}}}

  defp resolved(i), do: %{input: %{name: "Region #{i}"}}

  defp list_rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  describe ":next_pending_chunk" do
    test "returns chunk_size pending rows sorted by row_index" do
      bulk_action = create_bulk_action!(Enum.map(0..9, &pending/1))

      chunk =
        Row
        |> Ash.Query.for_read(:next_pending_chunk, %{
          bulk_action_id: bulk_action.id,
          chunk_size: 3
        })
        |> Ash.read!(authorize?: false)

      assert length(chunk) == 3
      assert Enum.map(chunk, & &1.row_index) == [0, 1, 2]
    end

    test "scopes by bulk_action_id" do
      bulk_action_a = create_bulk_action!(Enum.map(0..2, &pending/1))
      bulk_action_b = create_bulk_action!(Enum.map(10..12, &pending/1))

      chunk =
        Row
        |> Ash.Query.for_read(:next_pending_chunk, %{
          bulk_action_id: bulk_action_a.id,
          chunk_size: 10
        })
        |> Ash.read!(authorize?: false)

      assert Enum.all?(chunk, &(&1.bulk_action_id == bulk_action_a.id))
      refute Enum.any?(chunk, &(&1.bulk_action_id == bulk_action_b.id))
    end
  end

  describe "a row's status when stored" do
    test "is :pending with a reference, :resolved without one, :failed when its caller refused it" do
      refusal = Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "unreadable")

      bulk_action =
        create_bulk_action!([
          pending(0),
          resolved(1),
          %{target: %{tenant: {:lookup, AshBulkDurable.Test.Organization, :code, "O1"}}},
          %{input: %{name: "x"}, error: refusal}
        ])

      assert [
               %{status: :pending},
               %{status: :resolved, input: %{name: "Region 1"}},
               %{status: :pending},
               %{status: :failed, error: [%{message: message}]}
             ] = list_rows(bulk_action)

      assert message =~ "unreadable"
    end
  end

  describe ":next_resolved_chunk" do
    test "returns chunk_size resolved rows sorted by row_index" do
      bulk_action = create_bulk_action!(Enum.map(0..9, &resolved/1))

      chunk =
        Row
        |> Ash.Query.for_read(:next_resolved_chunk, %{
          bulk_action_id: bulk_action.id,
          chunk_size: 3
        })
        |> Ash.read!(authorize?: false)

      assert length(chunk) == 3
      assert Enum.map(chunk, & &1.row_index) == [0, 1, 2]
      assert Enum.all?(chunk, &(&1.status == :resolved))
    end

    test "excludes pending rows" do
      bulk_action = create_bulk_action!(Enum.map(0..2, &pending/1))

      chunk =
        Row
        |> Ash.Query.for_read(:next_resolved_chunk, %{
          bulk_action_id: bulk_action.id,
          chunk_size: 10
        })
        |> Ash.read!(authorize?: false)

      assert chunk == []
    end
  end

  describe ":mark_succeeded / :mark_failed" do
    test "flips status to :succeeded with record_id, and :failed with error" do
      bulk_action = create_bulk_action!([resolved(0), resolved(1)])
      [row_a, row_b] = list_rows(bulk_action)

      ok = Ash.update!(row_a, %{record_id: "prod-1"}, action: :mark_succeeded, authorize?: false)
      assert ok.status == :succeeded
      assert ok.record_id == "prod-1"

      refusal = Ash.Error.Changes.InvalidAttribute.exception(field: :sku, message: "is taken")

      bad = Ash.update!(row_b, %{error: refusal}, action: :mark_failed, authorize?: false)

      assert bad.status == :failed

      assert [%AshBulkDurable.Core.StoredError{error: stored, message: message}] =
               Ash.get!(Row, bad.id, authorize?: false).error

      assert %Ash.Error.Changes.InvalidAttribute{field: :sku} = stored
      assert message =~ "is taken"
    end
  end

  # What the resolve phase resolved survives a correction only where the
  # reference behind it is unchanged.
  describe ":reopen_with_corrections" do
    setup do
      photo = {:resolve, AshBulkDurable.TestResolver, %{file: "a.jpg"}}
      tenant = {:lookup, AshBulkDurable.Test.Organization, :code, "O1"}

      bulk_action =
        create_bulk_action!([
          %{
            target: %{tenant: tenant},
            input: %{name: "Alpha", photo: photo},
            metadata: %{"n" => "1"}
          }
        ])

      [row] = list_rows(bulk_action)

      row = Ash.Seed.update!(row, %{resolved_data: %{"photo" => %{"key" => "x"}}})

      {:ok, row} =
        row
        |> Ash.Changeset.for_update(:mark_failed, %{error: "oops"}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:resolved_tenant, "org-1")
        |> Ash.update(authorize?: false)

      %{row: row, photo: photo, tenant: tenant}
    end

    test "drops what a changed reference resolved to and flips to :pending", %{
      row: row,
      tenant: tenant
    } do
      new_photo = {:resolve, AshBulkDurable.TestResolver, %{file: "b.jpg"}}

      reopened =
        Ash.update!(
          row,
          %{input: %{name: "Alpha", photo: new_photo}, metadata: %{"n" => "2"}},
          action: :reopen_with_corrections,
          authorize?: false
        )

      assert reopened.status == :pending
      assert reopened.error == nil
      assert reopened.input == %{name: "Alpha", photo: new_photo}
      assert reopened.metadata == %{"n" => "2"}
      refute Map.has_key?(reopened.resolved_data, "photo")
      # The target was not corrected, so its tenant stays resolved.
      assert reopened.target == %{tenant: tenant}
      assert reopened.resolved_tenant == "org-1"
    end

    test "keeps what an unchanged reference resolved to", %{row: row, photo: photo} do
      reopened =
        Ash.update!(row, %{input: %{name: "Alpha Fixed", photo: photo}},
          action: :reopen_with_corrections,
          authorize?: false
        )

      assert reopened.status == :pending
      assert reopened.resolved_data["photo"] == %{"key" => "x"}
    end

    test "resolves a corrected tenant again", %{row: row} do
      other = {:lookup, AshBulkDurable.Test.Organization, :code, "O2"}

      reopened =
        Ash.update!(row, %{target: %{tenant: other}},
          action: :reopen_with_corrections,
          authorize?: false
        )

      assert reopened.resolved_tenant == nil
      assert reopened.status == :pending
    end

    test "a correction holding no reference is :resolved; one its caller refused stays :failed",
         %{row: row} do
      plain =
        Ash.update!(row, %{input: %{name: "Plain"}, target: %{tenant: "org-9"}},
          action: :reopen_with_corrections,
          authorize?: false
        )

      assert plain.status == :resolved

      refused =
        Ash.update!(plain, %{error: "unreadable cell"},
          action: :reopen_with_corrections,
          authorize?: false
        )

      assert refused.status == :failed
      assert [%{message: "unreadable cell"}] = refused.error
    end
  end

  describe ":reopen_with_corrections on a row running with the shared input" do
    setup do
      photo = {:resolve, AshBulkDurable.TestResolver, %{file: "a.jpg"}}
      [row] = [%{}] |> create_bulk_action!(%{name: "Alpha", photo: photo}) |> list_rows()

      assert row.input == nil
      assert row.status == :pending

      row =
        row
        |> Ash.Seed.update!(%{resolved_data: %{"photo" => %{"key" => "x"}}})
        |> Ash.update!(%{error: "oops"}, action: :mark_failed, authorize?: false)

      %{row: row, photo: photo}
    end

    test "uncorrected, it keeps no input of its own and what the shared one resolved to",
         %{row: row} do
      reopened = Ash.update!(row, %{}, action: :reopen_with_corrections, authorize?: false)

      assert reopened.input == nil
      assert reopened.status == :pending
      assert reopened.resolved_data["photo"] == %{"key" => "x"}
    end

    test "its own input keeps what a reference unchanged from the shared one resolved to",
         %{row: row, photo: photo} do
      reopened =
        Ash.update!(row, %{input: %{name: "Own", photo: photo}},
          action: :reopen_with_corrections,
          authorize?: false
        )

      assert reopened.input == %{name: "Own", photo: photo}
      assert reopened.status == :pending
      assert reopened.resolved_data["photo"] == %{"key" => "x"}
    end

    test "its own input replacing the reference drops it and needs no resolving", %{row: row} do
      reopened =
        Ash.update!(row, %{input: %{name: "Own"}},
          action: :reopen_with_corrections,
          authorize?: false
        )

      assert reopened.status == :resolved
      assert reopened.resolved_data == %{}
    end
  end
end
