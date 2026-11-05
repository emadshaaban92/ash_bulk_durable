defmodule AshBulkDurable.Core.StoredErrorTest do
  @moduledoc """
  What a bulk action keeps of a refusal: each leaf exception, stripped of
  what is heavy or personal, beside a clean English message — and that
  message alone when the exception can no longer be decoded.
  """
  use AshBulkDurable.DataCase, async: true

  alias AshBulkDurable.Core.StoredError
  alias AshBulkDurable.Test.Region

  defmodule ChangesetHoldingError do
    @moduledoc false
    defexception [:changeset, :message]
  end

  defp invalid_region_error(actor) do
    {:error, error} =
      Region
      |> Ash.Changeset.for_create(
        :create,
        %{name: "x", code: "c#{System.unique_integer([:positive])}"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    error
  end

  defp messages(stored), do: Enum.map_join(stored, "; ", & &1.message)

  describe "from/1" do
    test "an Ash validation error → its leaf, a clean field message, no stacktrace", %{
      super_user: user
    } do
      stored = StoredError.from(invalid_region_error(user))

      assert [_ | _] = stored
      assert messages(stored) =~ "native_name"
      assert messages(stored) =~ "required"
      refute messages(stored) =~ "(ash"
      refute messages(stored) =~ "lib/ash"
      assert Enum.all?(stored, &(is_exception(&1.error) and &1.error.stacktrace == nil))
    end

    test "a bare term → inspected, not crashed" do
      assert [%StoredError{error: nil, message: ":resolution_failed"}] =
               StoredError.from(:resolution_failed)
    end

    # `Ash.bulk_update` surfaces a DB-constraint failure as the errored
    # `%Ash.Changeset{}` (not an `Ash.Error.*`). It must store the changeset's
    # field error — not the changeset itself.
    test "an %Ash.Changeset{} → its field error, not the changeset", %{super_user: user} do
      changeset =
        Region
        |> Ash.Changeset.for_create(
          :create,
          %{name: "x", native_name: "y", code: "c#{System.unique_integer([:positive])}"},
          actor: user
        )
        |> Ash.Changeset.add_error(field: :code, message: "has already been taken")

      stored = StoredError.from(changeset)

      assert messages(stored) =~ "code"
      assert messages(stored) =~ "has already been taken"
      refute messages(stored) =~ "Ash.Changeset"
      refute messages(stored) =~ "attributes:"
      assert [%StoredError{error: %Ash.Error.Changes.InvalidAttribute{field: :code}}] = stored
    end

    test "a policy refusal keeps neither the actor nor what it was checked against", %{
      super_user: user
    } do
      refusal =
        Ash.Error.Forbidden.Policy.exception(
          actor: user,
          facts: %{checked: true},
          filter: :some_filter,
          policies: [:some_policy]
        )

      assert [%StoredError{error: stored}] = StoredError.from(refusal)

      assert %Ash.Error.Forbidden.Policy{actor: nil, facts: nil, filter: nil, policies: nil} =
               stored
    end

    # Ash's own leaves hold a query at most, and a package's error can hold
    # either, so these are built by hand: no row's refusal is known to.
    test "an error holding its query or changeset keeps neither" do
      query = Ash.Query.new(Region)
      changeset = Ash.Changeset.new(Region)

      assert [%StoredError{error: %Ash.Error.Invalid.MultipleResults{query: nil}}] =
               StoredError.from(Ash.Error.Invalid.MultipleResults.exception(query: query))

      assert [%StoredError{error: %ChangesetHoldingError{changeset: nil}}] =
               StoredError.from(%ChangesetHoldingError{changeset: changeset, message: "refused"})
    end
  end

  describe "decode/1" do
    test "round-trips what encode/1 stored", %{super_user: user} do
      stored = StoredError.from(invalid_region_error(user))

      assert stored |> StoredError.encode() |> StoredError.decode() == stored
    end

    # A struct whose module was renamed since it was stored names an atom the
    # VM no longer has, so `:safe` refuses it; the message must survive.
    test "an exception that no longer decodes leaves its message" do
      known = :erlang.term_to_binary(:stored_error_test_placeholder)
      # Same length as the placeholder, so the encoded atom's size still holds.
      unknown_name = binary_part("zq" <> Base.encode16(:crypto.strong_rand_bytes(14)), 0, 29)
      unknown = :binary.replace(known, "stored_error_test_placeholder", unknown_name)

      outer = :erlang.term_to_binary([{"code: has already been taken", unknown}])

      assert [%StoredError{error: nil, message: "code: has already been taken"}] =
               StoredError.decode(outer)
    end
  end
end
