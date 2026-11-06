defmodule AshBulkDurable.Stress.Applied do
  @moduledoc """
  The stress test's target: each record is one committed application of a
  row, written in the target action's own transaction, so a rolled-back
  write leaves none. Its `:apply` action fails a `"bad:"` value with an error
  of its own, kills its run on a `"kill:"` value, and records the row it
  applied (its owner and `row_index`, which rows running the bulk action's
  shared input share nothing else to tell them apart by) and the pass of the
  bulk action it ran under, read under that bulk action's lock.

  Only `test/stress/overlap_stress_test.exs` uses it, and creates its table
  itself, so the test repo's migrations don't carry it.
  """
  use Ash.Resource,
    domain: AshBulkDurable.Stress.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "stress_applied"
    repo AshBulkDurable.Test.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :owner_id, :uuid, allow_nil?: false, public?: true
    attribute :row_index, :integer, public?: true
    attribute :value, :string, allow_nil?: false, public?: true
    attribute :pass, :integer, public?: true
  end

  actions do
    defaults [:read]

    create :apply do
      accept [:value, :owner_id]
      change AshBulkDurable.Stress.Apply
    end
  end
end

defmodule AshBulkDurable.Stress.Apply do
  @moduledoc """
  Runs inside the chunk's transaction. The pass comes from the bulk action's
  row, locked with `SKIP LOCKED`: the transaction holding the lock gets it
  back at once, so a write made while another transaction holds the lock, or
  once the bulk action is no longer runnable, records `-1`.
  """
  use Ash.Resource.Change

  alias AshBulkDurable.Test.Repo

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &apply_row/1)

  defp apply_row(changeset) do
    case Ash.Changeset.get_attribute(changeset, :value) do
      "kill:" <> _ ->
        Process.exit(self(), :kill)

      "bad:" <> _ = value ->
        Ash.Changeset.add_error(changeset, field: :value, message: "refused #{value}")

      _good ->
        owner_id = Ash.Changeset.get_attribute(changeset, :owner_id)

        changeset
        |> Ash.Changeset.force_change_attribute(:pass, locked_pass(owner_id))
        |> Ash.Changeset.force_change_attribute(
          :row_index,
          changeset.context.ash_bulk_durable.row_index
        )
    end
  end

  defp locked_pass(owner_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT pass FROM bulk_actions WHERE user_id = $1 AND status IN ('queued', 'running') " <>
          "FOR NO KEY UPDATE SKIP LOCKED",
        [Ecto.UUID.dump!(owner_id)]
      )

    case rows do
      [[pass]] -> pass
      [] -> -1
    end
  end
end

defmodule AshBulkDurable.Stress.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshBulkDurable.Stress.Applied
  end
end
