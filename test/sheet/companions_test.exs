defmodule AshBulkDurable.Sheet.CompanionsTest do
  @moduledoc """
  A sheet is staged only with companion files its owner staged, meeting
  each mapped field's requirement (`AshBulkDurable.Sheet.Companions`).

  A browser never names a staging key: the screens compute it when they
  presign the upload, so no page can forge one and the check is driven
  through `AshBulkDurable.Sheet.stage/3`, where any stager reaches it.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  import ExUnit.CaptureLog

  alias AshBulkDurable.Core.Worker
  alias AshBulkDurable.Sheet
  alias AshBulkDurable.Sheet.Mapping
  alias AshBulkDurable.Test.BulkAction
  alias AshBulkDurable.Test.Booking
  alias AshBulkDurable.Test.Scope

  # A holder change's `document` is an array of files, whose
  # handler needs a ZIP staged beside the sheet.
  defp mapping(columns \\ %{id: "booking", document: "documents"}) do
    %Mapping{
      resource: Booking,
      action: Ash.Resource.Info.action(Booking, :change_holder),
      identity: Mapping.lookup_identity(Booking, :primary_key),
      columns: columns
    }
  end

  defp stage(ctx, companions, mapping \\ mapping()) do
    Sheet.stage([%{"booking" => "L1", "documents" => "a.pdf"}], mapping,
      scope: Scope.new(actor: ctx.super_user),
      companions: companions
    )
  end

  defp key(owner, file), do: "bulk-staging/#{owner}/#{Ecto.UUID.generate()}/companions/#{file}"

  defp stored_count(ctx) do
    BulkAction
    |> Ash.Query.filter(user_id == ^ctx.super_user.id)
    |> Ash.count!(authorize?: false)
  end

  test "accepts a ZIP under the owner's staging prefix and keeps it", ctx do
    key = key(ctx.super_user.id, "certificates.zip")

    assert {:ok, %BulkAction{} = bulk_action} = stage(ctx, %{document: key})
    assert bulk_action.staged_files == %{"document" => key}
  end

  test "refuses a key under another user's staging prefix", ctx do
    key = key(Ecto.UUID.generate(), "certificates.zip")

    assert {:error, %Ash.Error.Invalid{}} = stage(ctx, %{document: key})
    assert stored_count(ctx) == 0
  end

  test "refuses a `..` traversal key even though it starts with the prefix", ctx do
    # Starts with `bulk-staging/<user_id>/` yet normalizes into `public/`.
    key = "bulk-staging/#{ctx.super_user.id}/../../public/evil.zip"

    assert {:error, %Ash.Error.Invalid{}} = stage(ctx, %{document: key})
    assert stored_count(ctx) == 0
  end

  test "refuses a mapped field whose requirement no staged file meets", ctx do
    assert {:error, %Ash.Error.Invalid{errors: [%{field: :document} = missing]}} =
             stage(ctx, %{})

    assert Exception.message(missing) =~ "no file is staged"

    pdf = key(ctx.super_user.id, "certificates.pdf")

    assert {:error, %Ash.Error.Invalid{errors: [%{field: :document} = wrong]}} =
             stage(ctx, %{document: pdf})

    assert Exception.message(wrong) =~ ".zip"
    assert stored_count(ctx) == 0
  end

  test "a field the mapping leaves out needs no file", ctx do
    assert {:ok, %BulkAction{}} = stage(ctx, %{}, mapping(%{id: "booking"}))
  end

  describe "a retry staging them again" do
    setup ctx do
      key = key(ctx.super_user.id, "certificates.zip")
      {:ok, bulk_action} = stage(ctx, %{document: key})

      # The stub storage has no file to give, so the row fails without it.
      capture_log(fn -> :ok = Worker.run_now(bulk_action.id) end)
      parked = Ash.get!(BulkAction, bulk_action.id, authorize?: false)
      assert parked.status == :completed_with_errors

      %{bulk_action: parked, key: key}
    end

    defp retry(ctx, companions) do
      AshBulkDurable.retry(ctx.bulk_action, %Sheet{},
        scope: Scope.new(actor: ctx.super_user),
        companions: companions
      )
    end

    defp held(ctx), do: Ash.get!(BulkAction, ctx.bulk_action.id, authorize?: false)

    test "takes a ZIP under the owner's staging prefix in place of the old one", ctx do
      new_key = key(ctx.super_user.id, "certificates.zip")

      assert {:ok, %BulkAction{}} = retry(ctx, %{document: new_key})
      assert %{staged_files: %{"document" => ^new_key}} = held(ctx)
    end

    test "is checked as the sheet's were, nothing written when refused", ctx do
      for companions <- [
            %{document: key(Ecto.UUID.generate(), "certificates.zip")},
            %{document: "bulk-staging/#{ctx.super_user.id}/../../public/evil.zip"},
            %{document: key(ctx.super_user.id, "certificates.pdf")},
            %{}
          ] do
        assert {:error, %Ash.Error.Invalid{}} = retry(ctx, companions)
      end

      assert %{status: :completed_with_errors, staged_files: %{"document" => key}} = held(ctx)
      assert key == ctx.key
    end
  end
end
