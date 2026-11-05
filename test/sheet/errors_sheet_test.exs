defmodule AshBulkDurable.Sheet.ErrorsSheetTest do
  @moduledoc """
  The errors sheet out and back, as a script drives it: `errors_sheet/2`,
  a user's edits through a real CSV file, `read_sheet/2`, `retry/3`, and the
  worker running what they changed. It has one shape whichever source the
  bulk action started from.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Sheet
  alias AshBulkDurable.Sheet.{ErrorsSheet, Field, Mapping}
  alias AshBulkDurable.EchoResolver
  alias AshBulkDurable.Test.{BulkAction, FilesHandler, Row, StoredFile}
  alias AshBulkDurable.Test.Asset
  alias AshBulkDurable.Test.{Booking, Branch}
  alias AshBulkDurable.Test.Region

  setup %{super_user: user} do
    %{user: user, scope: AshBulkDurable.Test.Scope.new(actor: user)}
  end

  defp tag, do: "F#{System.unique_integer([:positive])}"

  defp region_input(tag \\ tag()),
    do: %{code: tag, name: "Region #{tag}", native_name: "منطقة #{tag}"}

  defp run!(bulk_action) do
    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()
    Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending])
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp reload_row(row), do: Ash.get!(Row, row.id, authorize?: false)

  # Saves the sheet as a user's spreadsheet would, `edit` changing each row.
  defp corrected(bulk_action, edit) do
    path = Path.join(System.tmp_dir!(), "errors_#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(path) end)

    sheet = AshBulkDurable.errors_sheet(bulk_action)
    edited = %{sheet | rows: Enum.map(sheet.rows, edit)}
    File.write!(path, edited |> Sheet.to_csv() |> Enum.to_list())

    {:ok, read} = AshBulkDurable.read_sheet(path)
    read
  end

  # A failed row holding what the resolve phase found.
  defp fail_with_resolved!(row, resolved) do
    row
    |> Ash.Seed.update!(%{resolved_data: resolved})
    |> Ash.update!(%{error: "boom"}, action: :mark_failed, authorize?: false)
  end

  defp with_errors!(bulk_action) do
    Ash.update!(bulk_action, %{result: :completed_with_errors},
      action: :mark_finished,
      authorize?: false
    )
  end

  defp branch_mapping do
    %Mapping{
      resource: Branch,
      action: Ash.Resource.Info.action(Branch, :create),
      columns: %{name: "Branch", region: "Area"},
      rel_identities: %{region: :code}
    }
  end

  defp stage_branches!(scope) do
    sheet_rows = Enum.map(1..3, &%{"Branch" => "Branch #{tag()}#{&1}", "Area" => "G#{&1}"})
    {:ok, bulk_action} = Sheet.stage(sheet_rows, branch_mapping(), scope: scope)
    bulk_action
  end

  describe "errors_sheet/2" do
    test "a plain value has no cell under a composite lookup's columns", ctx do
      serial = "SN#{tag()}"
      batch = "BA#{tag()}"
      asset_lookup = %{serial_number: serial, batch_number: batch}
      plain = Ecto.UUID.generate()

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(
          [
            %{asset_id: {:lookup, Asset, :serial_and_batch, asset_lookup}},
            %{asset_id: plain}
          ],
          Booking,
          :import,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      assert bulk_action.status == :completed_with_errors
      [looked_up, held] = rows(bulk_action)

      sheet = AshBulkDurable.errors_sheet(bulk_action)

      assert "asset_id.serial_number" in sheet.headers
      assert Enum.all?(sheet.headers, &is_binary/1)
      assert sheet |> Sheet.to_csv() |> Enum.to_list() |> IO.iodata_to_binary() =~ serial

      assert %{"asset_id.serial_number" => ^serial} =
               ErrorsSheet.cells(bulk_action, looked_up)

      # Beside a composite lookup the sheet has no column for it; the `/bulk`
      # preview shapes itself by the row alone, so it still shows the value.
      held_cells = Enum.find(sheet.rows, &(&1["row_id"] == held.id))
      assert Map.keys(held_cells) |> Enum.sort() == ["last_error", "row_id"]
      assert ErrorsSheet.cells(bulk_action, held) == %{"asset_id" => plain}

      # A cell reads back only where it changed, so the row keeps its value.
      read = corrected(bulk_action, & &1)

      assert {:ok, corrections} = ErrorsSheet.corrections(bulk_action, read, ctx.scope)
      assert corrections == %{looked_up.id => %{}, held.id => %{}}
    end

    test "is shaped by the action, not the file it started from", ctx do
      taken = region_input()
      Ash.create!(Region, taken, actor: ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(
          [region_input(), taken],
          Region,
          :create,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      [_good, failed] = rows(bulk_action)

      sheet = AshBulkDurable.errors_sheet(bulk_action)

      assert sheet.headers == ["row_id", "last_error", "code", "name", "native_name"]
      assert [row] = sheet.rows
      assert row["row_id"] == failed.id
      assert row["last_error"] =~ "taken"
      assert row["code"] == taken.code
      assert row["name"] == taken.name
      assert row["native_name"] == taken.native_name
    end

    test "words its errors as the caller asks", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([%{code: tag()}], Region, :create, scope: ctx.scope)

      bulk_action = run!(bulk_action)

      assert [%{"last_error" => "worded"}] =
               AshBulkDurable.errors_sheet(bulk_action, error: fn [_stored | _] -> "worded" end).rows
    end

    test "a selection shows its shared input on every row, and no target to change", ctx do
      [branch, other] =
        Enum.map(1..2, fn _n -> Ash.create!(Branch, %{name: tag()}, actor: ctx.user) end)

      code = tag()

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(
          [branch, other],
          :update,
          %{region_id: {:lookup, Region, :code, code}},
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      sheet = AshBulkDurable.errors_sheet(bulk_action)

      assert "region_id" in sheet.headers
      refute "id" in sheet.headers
      assert Enum.map(sheet.rows, & &1["region_id"]) == [code, code]
    end

    test "after a partial retry only the rows still failing are listed", ctx do
      inputs = [region_input(), region_input()]
      Enum.each(inputs, &Ash.create!(Region, &1, actor: ctx.user))

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(inputs, Region, :create, scope: ctx.scope)

      bulk_action = run!(bulk_action)
      assert length(AshBulkDurable.errors_sheet(bulk_action).rows) == 2

      [first, second] = rows(bulk_action)

      {:ok, _retried} =
        AshBulkDurable.retry_row(first, input: region_input(), scope: ctx.scope)

      bulk_action = run!(bulk_action)

      assert [%{"row_id" => id}] = AshBulkDurable.errors_sheet(bulk_action).rows
      assert id == second.id
    end

    test "all or nothing lists every row, the error on the one that stopped it", ctx do
      taken = region_input()
      Ash.create!(Region, taken, actor: ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([region_input(), taken], Region, :create,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      assert [%{"last_error" => ""}, %{"last_error" => error}] =
               AshBulkDurable.errors_sheet(run!(bulk_action)).rows

      assert error =~ "taken"
    end

    test "all or nothing puts a lookup that found nothing on the row that made it", ctx do
      found = Ash.create!(Region, region_input(), actor: ctx.user)
      missing = tag()

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [{%{code: found.code}, %{name: tag()}}, {%{code: missing}, %{name: tag()}}],
          Region,
          :update,
          identity: :code,
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      assert [%{"last_error" => ""}, %{"last_error" => error, "code" => code}] =
               AshBulkDurable.errors_sheet(run!(bulk_action)).rows

      assert error =~ ~s(code: "#{missing}" not found)
      assert code == missing
    end

    test "all or nothing puts a selected record since deleted on the row that held it", ctx do
      [kept, gone] =
        Enum.map(1..2, fn _n ->
          name = "Branch #{System.unique_integer([:positive])}"
          Ash.create!(Branch, %{name: name}, actor: ctx.user)
        end)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([kept, gone], :update, %{name: "Branch #{tag()}"},
          scope: ctx.scope,
          mode: :all_or_nothing
        )

      Ash.destroy!(gone, actor: ctx.user)

      assert [%{"last_error" => ""}, %{"last_error" => error}] =
               AshBulkDurable.errors_sheet(run!(bulk_action)).rows

      assert error =~ ~s(id: "#{gone.id}" not found)
    end

    test "is headers alone when no row is left", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.bulk_create([region_input()], Region, :create, scope: ctx.scope)

      sheet = AshBulkDurable.errors_sheet(run!(bulk_action))

      assert sheet.rows == []
      assert sheet.headers == ["row_id", "last_error", "code", "name", "native_name"]
    end
  end

  describe "retry/3 with a corrected sheet" do
    test "runs what changed, the corrected rows and the ones left as they were", ctx do
      inputs = [region_input(), region_input()]
      Enum.each(inputs, &Ash.create!(Region, &1, actor: ctx.user))

      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(inputs, Region, :create, scope: ctx.scope)

      bulk_action = run!(bulk_action)
      fixed = region_input()
      [first_code, _second] = Enum.map(inputs, & &1.code)

      sheet =
        corrected(bulk_action, fn
          %{"code" => ^first_code} = row ->
            %{
              row
              | "code" => fixed.code,
                "name" => fixed.name,
                "native_name" => fixed.native_name
            }

          row ->
            row
        end)

      assert {:ok, %{status: :queued}} =
               AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      bulk_action = run!(bulk_action)
      [first, second] = rows(bulk_action)

      assert first.status == :succeeded
      assert second.status == :failed
      assert bulk_action.status == :completed_with_errors
    end

    test "a row keeps what a cell left alone found; a changed cell looks it up again", ctx do
      [branch, other, taken] =
        Enum.map(1..3, fn _n ->
          Ash.create!(Branch, %{name: "Branch #{tag()}"}, actor: ctx.user)
        end)

      found = Ash.create!(Region, region_input(), actor: ctx.user)
      elsewhere = Ash.create!(Region, region_input(), actor: ctx.user)
      code = to_string(found.code)
      input = %{name: taken.name, region_id: {:lookup, Region, :code, code}}

      {:ok, bulk_action} =
        AshBulkDurable.update_many([{branch, input}, {other, input}], Branch, :update,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      assert Enum.map(rows(bulk_action), & &1.status) == [:failed, :failed]

      # Looked up again, the first row's unchanged cell would now find nothing.
      Ash.update!(found, %{code: tag()}, actor: ctx.user)
      [first_id, _second_id] = Enum.map(rows(bulk_action), & &1.id)

      sheet =
        corrected(bulk_action, fn
          %{"row_id" => ^first_id} = row ->
            %{row | "name" => "Branch #{tag()}"}

          row ->
            %{row | "name" => "Branch #{tag()}", "region_id" => to_string(elsewhere.code)}
        end)

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      assert run!(bulk_action).status == :completed
      assert Ash.reload!(branch, actor: ctx.user).region_id == found.id
      assert Ash.reload!(other, actor: ctx.user).region_id == elsewhere.id
    end

    test "a blank cell clears only what the row had; an input it never had stays unsent", ctx do
      holding = Ash.create!(Region, region_input(), actor: ctx.user)
      never_had = Ash.create!(Region, region_input(), actor: ctx.user)

      # Both fail: `name` is taken by another region.
      other = Ash.create!(Region, region_input(), actor: ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [
            {%{code: holding.code}, %{name: other.name, native_name: "Held #{tag()}"}},
            {%{code: never_had.code}, %{name: other.name}}
          ],
          Region,
          :update,
          identity: :code,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      [held_row, never_had_row] = rows(bulk_action)
      assert Enum.map([held_row, never_had_row], & &1.status) == [:failed, :failed]

      names = %{held_row.id => "Renamed #{tag()}", never_had_row.id => "Renamed #{tag()}"}

      sheet =
        corrected(
          bulk_action,
          &Map.merge(&1, %{"name" => names[&1["row_id"]], "native_name" => ""})
        )

      assert Enum.map(sheet.rows, & &1["native_name"]) == ["", ""]

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)
      bulk_action = run!(bulk_action)

      # The blank reaches the action in place of what the row held, which
      # `native_name` must have, so that row alone stays failed.
      assert bulk_action.status == :completed_with_errors

      held_row = reload_row(held_row)
      assert held_row.status == :failed
      assert held_row.input == %{name: names[held_row.id], native_name: ""}
      assert Enum.map_join(held_row.error, & &1.message) =~ "native_name is required"

      never_had_row = reload_row(never_had_row)
      assert never_had_row.status == :succeeded
      assert never_had_row.input == %{name: names[never_had_row.id]}

      assert Ash.reload!(holding, actor: ctx.user).name == holding.name

      updated = Ash.reload!(never_had, actor: ctx.user)
      assert updated.name == names[never_had_row.id]
      assert updated.native_name == never_had.native_name
    end

    test "a typo in an identity's cell moves the lookup", ctx do
      region = Ash.create!(Region, region_input(), actor: ctx.user)
      name = "Renamed #{tag()}"
      typo = tag()

      {:ok, bulk_action} =
        AshBulkDurable.update_many([{%{code: typo}, %{name: name}}], Region, :update,
          identity: :code,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      sheet = corrected(bulk_action, &%{&1 | "code" => to_string(region.code)})

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      assert run!(bulk_action).status == :completed
      assert Ash.reload!(region, actor: ctx.user).name == name
    end

    test "a column feeding both a lookup and an input moves both when they agreed", ctx do
      region = Ash.create!(Region, region_input(), actor: ctx.user)
      typo = tag()

      {:ok, bulk_action} =
        AshBulkDurable.update_many([{%{code: typo}, %{code: typo}}], Region, :update,
          identity: :code,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      [row] = rows(bulk_action)
      sheet = corrected(bulk_action, &%{&1 | "code" => to_string(region.code)})

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      reopened = reload_row(row)
      assert reopened.target.lookup == %{code: to_string(region.code)}
      assert reopened.input == %{code: to_string(region.code)}
    end

    test "a column showing a rename corrects the rename, not the lookup", ctx do
      code = tag()
      renamed = tag()
      corrected_rename = tag()

      {:ok, bulk_action} =
        AshBulkDurable.update_many([{%{code: code}, %{code: renamed}}], Region, :update,
          identity: :code,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      [row] = rows(bulk_action)

      assert [%{"code" => ^renamed}] = AshBulkDurable.errors_sheet(bulk_action).rows

      sheet = corrected(bulk_action, &%{&1 | "code" => corrected_rename})
      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      reopened = reload_row(row)
      assert reopened.target.lookup == %{code: code}
      assert reopened.input == %{code: corrected_rename}
    end

    test "correcting a row of a selection gives it its own input, the others keep the shared",
         ctx do
      [branch, other] =
        Enum.map(1..2, fn _n -> Ash.create!(Branch, %{name: tag()}, actor: ctx.user) end)

      shared_code = tag()
      own = Ash.create!(Region, region_input(), actor: ctx.user)
      shared = Ash.create!(Region, region_input(shared_code), actor: ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(
          [branch, other],
          :update,
          %{region_id: {:lookup, Region, :code, "#{shared_code}x"}},
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      [branch_row, other_row] = rows(bulk_action)

      sheet =
        corrected(bulk_action, fn
          %{"row_id" => id} = row when id == branch_row.id ->
            %{row | "region_id" => to_string(own.code)}

          row ->
            row
        end)

      {:ok, _retried} =
        AshBulkDurable.retry(bulk_action, sheet,
          input: %{region_id: {:lookup, Region, :code, shared_code}},
          scope: ctx.scope
        )

      assert run!(bulk_action).status == :completed
      assert reload_row(other_row).input == nil
      assert Ash.reload!(branch, actor: ctx.user).region_id == own.id
      assert Ash.reload!(other, actor: ctx.user).region_id == shared.id
    end

    test "a plain key a script gave stays a plain key when corrected", ctx do
      branch = Ash.create!(Branch, %{name: tag()}, actor: ctx.user)
      region = Ash.create!(Region, region_input(), actor: ctx.user)

      {:ok, bulk_action} =
        AshBulkDurable.update_many(
          [{branch, %{region_id: Ecto.UUID.generate()}}],
          Branch,
          :update,
          scope: ctx.scope
        )

      bulk_action = run!(bulk_action)
      assert bulk_action.status == :completed_with_errors

      sheet = corrected(bulk_action, &%{&1 | "region_id" => region.id})
      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      assert run!(bulk_action).status == :completed
      assert Ash.reload!(branch, actor: ctx.user).region_id == region.id
    end

    test "keeps what an unchanged lookup resolved to", ctx do
      bulk_action = stage_branches!(ctx.scope)
      [_first, second, _third] = rows(bulk_action)
      second = fail_with_resolved!(second, %{region_id: "RESOLVED_SENTINEL"})
      bulk_action = with_errors!(bulk_action)
      name = "Branch #{tag()}"

      sheet =
        corrected(bulk_action, fn
          %{"row_id" => id} = row when id == second.id -> %{row | "name" => name}
          row -> row
        end)

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      reopened = reload_row(second)
      assert reopened.status == :pending
      assert reopened.error == nil
      assert reopened.input.name == name
      assert reopened.resolved_data["region_id"] == "RESOLVED_SENTINEL"
    end

    test "drops what a corrected lookup resolved to", ctx do
      bulk_action = stage_branches!(ctx.scope)
      [_first, second, _third] = rows(bulk_action)
      second = fail_with_resolved!(second, %{region_id: "RESOLVED_SENTINEL"})
      bulk_action = with_errors!(bulk_action)

      sheet =
        corrected(bulk_action, fn
          %{"row_id" => id} = row when id == second.id -> %{row | "region_id" => "G9"}
          row -> row
        end)

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      reopened = reload_row(second)
      assert reopened.input.region_id == {:lookup, Region, :code, "G9"}
      refute Map.has_key?(reopened.resolved_data, "region_id")
    end

    test "a row the sheet names that is not left to run refuses the whole retry", ctx do
      bulk_action = stage_branches!(ctx.scope)
      [_first, second, _third] = rows(bulk_action)
      second = fail_with_resolved!(second, %{region_id: "S"})
      bulk_action = with_errors!(bulk_action)
      bogus = Ecto.UUID.generate()
      name = "Branch #{tag()}"

      jobs = fn ->
        BulkAction
        |> Ash.get!(bulk_action.id, authorize?: false)
        |> Map.take([:status, :updated_at])
      end

      jobs_before = jobs.()

      sheet = %Sheet{
        rows: [%{"row_id" => second.id, "name" => name}, %{"row_id" => bogus, "name" => "x"}]
      }

      assert {:error, %{unmatched: [^bogus]}} =
               AshBulkDurable.retry(bulk_action, sheet, scope: ctx.scope)

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).status ==
               :completed_with_errors

      assert reload_row(second).status == :failed
      assert jobs.() == jobs_before
    end
  end

  describe "cells/2" do
    test "holds what a row has, for the preview", ctx do
      bulk_action = stage_branches!(ctx.scope)
      [first | _rows] = rows(bulk_action)

      assert %{"name" => "Branch " <> _name, "region_id" => "G1"} =
               cells = ErrorsSheet.cells(bulk_action, first)

      refute Map.has_key?(cells, "row_id")
    end

    test "a sheet's lookup narrowed through a relationship shows and corrects by its key", ctx do
      region = Ash.create!(Region, region_input(), actor: ctx.user)

      mapping = %Mapping{
        resource: Region,
        action: Ash.Resource.Info.action(Region, :update),
        identity: Ash.Resource.Info.identity(Region, :code),
        columns: %{code: "Code", name: "Name"},
        tenant_mapping: %{rel_name: :inserted_by, identity: :email, csv_col: "By"}
      }

      {:ok, bulk_action} =
        Sheet.stage(
          [%{"Code" => region.code, "Name" => "x", "By" => "typo@example.com"}],
          mapping,
          scope: ctx.scope
        )

      [row] = rows(bulk_action)

      assert %{"code" => _code, "inserted_by.email" => "typo@example.com"} =
               ErrorsSheet.cells(bulk_action, row)

      sheet = %Sheet{rows: [%{"row_id" => row.id, "inserted_by.email" => "right@example.com"}]}

      assert {:ok, %{^row => %{lookup: %{inserted_by: %{email: "right@example.com"}}}}} =
               bulk_action
               |> ErrorsSheet.corrections(sheet, ctx.scope)
               |> then(fn {:ok, corrections} ->
                 {:ok, %{row => Map.fetch!(corrections, row.id)}}
               end)
    end
  end

  describe "a handler's reference reads back as its cell" do
    test "a field of files shows the file names its cell gave" do
      field = %Field{
        field: %{name: :photos, type: {:array, StoredFile}},
        resource: Branch,
        action: %{name: :update}
      }

      assert {:ok, {:resolve, EchoResolver, %{filenames: ["a.jpg", "b.jpg"]}} = value} =
               FilesHandler.input_value(field, "a.jpg|b.jpg", nil)

      assert FilesHandler.to_cell(field, value) == "a.jpg|b.jpg"
    end

    test "a composite lookup gives a cell per key" do
      value = {:lookup, Region, :code_name, %{code: "C1", name: nil}}

      assert AshBulkDurable.Sheet.FieldHandlers.BelongsTo.to_cell(nil, value) ==
               %{code: "C1", name: ""}
    end
  end
end
