defmodule AshBulkDurable.Core.Resource.BulkAction.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.{Dsl, Info}
  alias Spark.Dsl.Transformer

  @impl true
  def after?(_), do: false

  @impl true
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    {:ok,
     dsl_state
     |> add_primary_key()
     |> add_attribute(:user_id, :uuid, allow_nil?: false, public?: true)
     |> add_attribute(:resource_name, :string, allow_nil?: false, public?: true)
     |> add_attribute(:action_name, :string, allow_nil?: false, public?: true)
     |> add_attribute(:action_type, :atom,
       allow_nil?: false,
       public?: true,
       constraints: [one_of: [:create, :update, :destroy]]
     )
     |> add_attribute(:tenant, AshBulkDurable.Core.StoredTerm, allow_nil?: true, public?: true)
     |> add_attribute(:input, AshBulkDurable.Core.StoredTerm, allow_nil?: true, public?: true)
     |> add_attribute(:staged_files, :map, allow_nil?: false, public?: true, default: %{})
     |> add_attribute(:metadata, :map, allow_nil?: false, public?: true, default: %{})
     |> add_attribute(:status, :atom,
       allow_nil?: false,
       public?: true,
       default: :queued,
       constraints: [
         one_of: [:queued, :running, :completed, :completed_with_errors, :failed, :cancelled]
       ]
     )
     |> add_attribute(:total_rows, :integer, allow_nil?: false, public?: true)
     |> add_attribute(:mode, :atom,
       allow_nil?: false,
       public?: true,
       constraints: [one_of: [:per_row, :all_or_nothing]]
     )
     |> add_attribute(:chunk_size, :integer, allow_nil?: false, public?: true)
     |> add_attribute(:rows_done, :integer, allow_nil?: false, public?: true, default: 0)
     |> add_attribute(:error, AshBulkDurable.Core.StoredErrors, allow_nil?: true, public?: true)
     |> add_attribute(:result, :map, allow_nil?: true, public?: true)
     |> add_attribute(:started_at, :utc_datetime_usec, allow_nil?: true, public?: true)
     |> add_attribute(:finished_at, :utc_datetime_usec, allow_nil?: true, public?: true)
     |> add_attribute(:alive_at, :utc_datetime_usec, allow_nil?: true, public?: true)
     |> add_attribute(:stalled_starts, :integer, allow_nil?: false, public?: true, default: 0)
     |> add_attribute(:setup_failures, :integer, allow_nil?: false, public?: true, default: 0)
     |> add_attribute(:progress_at_start, :integer, allow_nil?: true, public?: true)
     |> add_attribute(:shutdown_stopped, :boolean,
       allow_nil?: false,
       public?: true,
       default: false
     )
     |> add_attribute(:isolating_row_id, :uuid, allow_nil?: true, public?: true)
     |> add_attribute(:pass, :integer, allow_nil?: false, public?: true, default: 0)
     |> add_create_timestamp(:inserted_at)
     |> add_update_timestamp(:updated_at)
     |> add_one_unresolved_identity()
     |> add_startable_index()
     |> add_default_accept()
     |> add_defaults()
     |> add_create_action()
     |> add_mark_running_action()
     |> add_stamp_alive_action()
     |> add_count_crashes_action()
     |> add_bump_rows_done_action()
     |> add_mark_finished_action()
     |> add_enqueue_retry_action()
     |> add_fetch_for_user_unresolved_action()
     |> add_fetch_for_user_by_id_action()
     |> add_pubsub_config()}
  end

  # ── Attribute helpers ────────────────────────────────────────────────────

  defp add_primary_key(dsl_state) do
    if Info.attribute(dsl_state, :id) do
      dsl_state
    else
      {:ok, pk} = Transformer.build_entity(Dsl, [:attributes], :uuid_v7_primary_key, name: :id)
      Transformer.add_entity(dsl_state, [:attributes], pk, type: :prepend)
    end
  end

  defp add_attribute(dsl_state, name, type, opts) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      opts =
        opts
        |> Keyword.put(:name, name)
        |> Keyword.put(:type, type)

      {:ok, attribute} = Transformer.build_entity(Dsl, [:attributes], :attribute, opts)
      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  defp add_create_timestamp(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(Dsl, [:attributes], :create_timestamp,
          name: name,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  defp add_update_timestamp(dsl_state, name) do
    if Info.attribute(dsl_state, name) do
      dsl_state
    else
      {:ok, attribute} =
        Transformer.build_entity(Dsl, [:attributes], :update_timestamp,
          name: name,
          public?: true
        )

      Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
    end
  end

  # ── Identity ─────────────────────────────────────────────────────────────

  # One *unresolved* bulk action per user: a bulk action holds the slot while it's queued,
  # running, or parked in `:completed_with_errors` — the user must finish,
  # retry-to-completion, or abandon an errored bulk action before starting
  # another. The status set is closed under every lifecycle transition (bulk actions
  # enter it only at user-initiated create; the worker's
  # `running → completed_with_errors` flip keeps the same indexed row), so
  # `mark_finished` can never hit a unique violation.
  defp add_one_unresolved_identity(dsl_state) do
    import Ash.Expr

    name = :one_unresolved_per_user

    existing =
      dsl_state
      |> Transformer.get_entities([:identities])
      |> Enum.find(&(&1.name == name))

    if existing do
      dsl_state
    else
      {:ok, identity} =
        Transformer.build_entity(Dsl, [:identities], :identity,
          name: name,
          keys: [:user_id],
          where: expr(status in [:queued, :running, :completed_with_errors])
        )

      Transformer.add_entity(dsl_state, [:identities], identity, type: :append)
    end
  end

  # What the poller reads every few seconds on every node: the few bulk
  # actions still queued or running, oldest first, out of the whole history.
  defp add_startable_index(dsl_state) do
    where = "status IN ('queued', 'running')"

    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.any?(&(&1.where == where))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          fields: [:inserted_at, :id],
          where: where
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end

  # ── Actions ──────────────────────────────────────────────────────────────

  defp add_default_accept(dsl_state) do
    case Transformer.get_option(dsl_state, [:actions], :default_accept) do
      nil -> Transformer.set_option(dsl_state, [:actions], :default_accept, [])
      _ -> dsl_state
    end
  end

  defp add_defaults(dsl_state) do
    existing = Transformer.get_option(dsl_state, [:actions], :defaults) || []

    has_read? =
      Enum.any?(existing, fn
        :read -> true
        {:read, _} -> true
        _ -> false
      end)

    has_destroy? =
      Enum.any?(existing, fn
        :destroy -> true
        {:destroy, _} -> true
        _ -> false
      end)

    additions =
      if(has_read?, do: [], else: [:read]) ++
        if has_destroy?, do: [], else: [:destroy]

    case additions do
      [] ->
        dsl_state

      additions ->
        Transformer.set_option(dsl_state, [:actions], :defaults, existing ++ additions)
    end
  end

  defp add_create_action(dsl_state) do
    if Info.action(dsl_state, :create) do
      dsl_state
    else
      accept = [
        :user_id,
        :resource_name,
        :action_name,
        :action_type,
        :tenant,
        :input,
        :staged_files,
        :metadata,
        :total_rows,
        :mode,
        :chunk_size
      ]

      rows_argument =
        Transformer.build_entity!(Dsl, [:actions, :create], :argument,
          name: :rows,
          type: {:array, :map},
          allow_nil?: false
        )

      validate_atomic_mode =
        Transformer.build_entity!(Dsl, [:actions, :create], :validate,
          validation: AshBulkDurable.Core.Changes.ValidateAtomicModeLimit
        )

      persist_rows =
        Transformer.build_entity!(Dsl, [:actions, :create], :change,
          change: AshBulkDurable.Core.Changes.PersistRows
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :create,
          name: :create,
          primary?: true,
          accept: accept,
          arguments: [rows_argument],
          changes: [
            validate_atomic_mode,
            persist_rows
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_mark_running_action(dsl_state) do
    if Info.action(dsl_state, :mark_running) do
      dsl_state
    else
      set_status =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: {Ash.Resource.Change.SetAttribute, [attribute: :status, value: :running]}
        )

      set_started_at =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change:
            {Ash.Resource.Change.SetAttribute,
             [attribute: :started_at, value: &DateTime.utc_now/0]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :mark_running,
          accept: [],
          require_atomic?: false,
          changes: [set_status, set_started_at]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # The liveness hint (`AshBulkDurable.Core.Liveness`), on the database's
  # clock, so nodes whose clocks differ agree on how old it is. The clock as
  # the stamp is written, not `now()`, the transaction's start: a stamp a
  # long chunk writes last would otherwise commit already stale.
  defp add_stamp_alive_action(dsl_state) do
    if Info.action(dsl_state, :stamp_alive) do
      dsl_state
    else
      import Ash.Expr

      stamp =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change:
            {Ash.Resource.Change.Atomic,
             [
               attribute: :alive_at,
               expr: expr(fragment("(clock_timestamp() AT TIME ZONE 'utc')")),
               cast_atomic?: true
             ]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :stamp_alive,
          accept: [],
          changes: [stamp]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # What a run keeps to tell a run that keeps dying from one that makes
  # progress (see "Crashes" in `AshBulkDurable.Core.Worker`), written under
  # the lock. Nothing a page shows.
  defp add_count_crashes_action(dsl_state) do
    if Info.action(dsl_state, :count_crashes) do
      dsl_state
    else
      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :count_crashes,
          accept: [
            :stalled_starts,
            :setup_failures,
            :progress_at_start,
            :shutdown_stopped,
            :isolating_row_id
          ]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_bump_rows_done_action(dsl_state) do
    if Info.action(dsl_state, :bump_rows_done) do
      dsl_state
    else
      import Ash.Expr

      n_argument =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :n,
          type: :integer,
          allow_nil?: false,
          default: 1
        )

      atomic_bump =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change:
            {Ash.Resource.Change.Atomic,
             [attribute: :rows_done, expr: expr(rows_done + ^arg(:n)), cast_atomic?: true]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :bump_rows_done,
          accept: [],
          arguments: [n_argument],
          changes: [atomic_bump]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_mark_finished_action(dsl_state) do
    if Info.action(dsl_state, :mark_finished) do
      dsl_state
    else
      result_argument =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :result,
          type: :term,
          allow_nil?: false
        )

      apply_change =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.ApplyMarkFinished
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :mark_finished,
          accept: [],
          require_atomic?: false,
          arguments: [result_argument],
          changes: [apply_change]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_enqueue_retry_action(dsl_state) do
    if Info.action(dsl_state, :enqueue_retry) do
      dsl_state
    else
      input_argument =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :input,
          type: :term,
          allow_nil?: true
        )

      pass_argument =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :pass,
          type: :integer,
          allow_nil?: true
        )

      staged_files_argument =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :staged_files,
          type: :map,
          allow_nil?: true
        )

      reopen =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.ReopenBulkAction
        )

      set_status =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: {Ash.Resource.Change.SetAttribute, [attribute: :status, value: :queued]}
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :enqueue_retry,
          accept: [],
          require_atomic?: false,
          arguments: [input_argument, pass_argument, staged_files_argument],
          changes: [reopen, set_status]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Fetches the bulk action currently holding the user's one-unresolved slot — the
  # same status set as the `:one_unresolved_per_user` identity, so mount
  # reattaches a parked `:completed_with_errors` bulk action just like a live one.
  defp add_fetch_for_user_unresolved_action(dsl_state) do
    if Info.action(dsl_state, :fetch_for_user_unresolved) do
      dsl_state
    else
      import Ash.Expr

      user_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :user_id,
          type: :uuid,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter:
            expr(
              user_id == ^arg(:user_id) and
                status in [:queued, :running, :completed_with_errors]
            )
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :fetch_for_user_unresolved,
          get?: true,
          arguments: [user_id_arg],
          filters: [filter]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Fetches a specific bulk action by id, gated on `user_id` so a deep-link to
  # `/bulk?bulk_action=<id>` can only reattach bulk actions the current user owns
  # (the URL is a meaningful deep-link). Status is unrestricted —
  # the LV is the policy point for which statuses are user-visible —
  # but mount's auto-attach via `:fetch_for_user_unresolved` always wins,
  # so in practice this serves terminal (`:completed` / `:failed` /
  # `:cancelled`) bulk actions.
  defp add_fetch_for_user_by_id_action(dsl_state) do
    if Info.action(dsl_state, :fetch_for_user_by_id) do
      dsl_state
    else
      import Ash.Expr

      user_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :user_id,
          type: :uuid,
          allow_nil?: false
        )

      id_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :id,
          type: :uuid,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter: expr(id == ^arg(:id) and user_id == ^arg(:user_id))
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :fetch_for_user_by_id,
          get?: true,
          arguments: [user_id_arg, id_arg],
          filters: [filter]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── PubSub ───────────────────────────────────────────────────────────────

  defp add_pubsub_config(dsl_state) do
    case Transformer.get_option(dsl_state, [:pub_sub], :module) do
      nil ->
        case AshBulkDurable.Core.config(:pubsub_module) do
          nil ->
            dsl_state

          module ->
            dsl_state
            |> Transformer.set_option([:pub_sub], :module, module)
            |> Transformer.set_option([:pub_sub], :prefix, "bulk_action")
            |> Transformer.set_option([:pub_sub], :broadcast_type, :notification)
            |> Transformer.set_option([:pub_sub], :delimiter, ":")
            |> add_publish_all_update()
        end

      _ ->
        dsl_state
    end
  end

  defp add_publish_all_update(dsl_state) do
    existing = Transformer.get_entities(dsl_state, [:pub_sub])

    has_update? =
      Enum.any?(existing, fn
        %{action: :update, type: :update} -> true
        %{type: :update} -> true
        _ -> false
      end)

    if has_update? do
      dsl_state
    else
      {:ok, publish_all} =
        Transformer.build_entity(Ash.Notifier.PubSub, [:pub_sub], :publish_all,
          type: :update,
          topic: [:id]
        )

      Transformer.add_entity(dsl_state, [:pub_sub], publish_all, type: :append)
    end
  end
end
