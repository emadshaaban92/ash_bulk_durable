defmodule AshBulkDurable.Core.Resource.Row.Transformer do
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
     |> add_attribute(:row_index, :integer, allow_nil?: false, public?: true)
     |> add_attribute(:target, AshBulkDurable.Core.StoredTerm, allow_nil?: true, public?: true)
     |> add_attribute(:input, AshBulkDurable.Core.StoredTerm, allow_nil?: true, public?: true)
     |> add_attribute(:metadata, :map, allow_nil?: false, public?: true, default: %{})
     |> add_attribute(:resolved_data, :map, allow_nil?: false, public?: true, default: %{})
     |> add_attribute(:resolved_tenant, AshBulkDurable.Core.StoredTerm,
       allow_nil?: true,
       public?: true
     )
     |> add_attribute(:status, :atom,
       allow_nil?: false,
       public?: true,
       default: :pending,
       constraints: [one_of: [:pending, :resolved, :succeeded, :failed]]
     )
     |> add_attribute(:error, AshBulkDurable.Core.StoredErrors, allow_nil?: true, public?: true)
     |> add_attribute(:refused, :boolean, allow_nil?: false, public?: true, default: false)
     |> add_attribute(:record_id, :string, allow_nil?: true, public?: true)
     |> add_create_timestamp(:inserted_at)
     |> add_bulk_action_relationship()
     |> add_default_accept()
     |> add_defaults()
     |> add_bulk_create_action()
     |> add_next_pending_chunk_action()
     |> add_next_resolved_chunk_action()
     |> add_forget_resolutions_action()
     |> add_resolve_action()
     |> add_mark_succeeded_action()
     |> add_mark_failed_action()
     |> add_run_action()
     |> add_reopen_with_corrections_action()
     |> add_postgres_reference()
     |> add_status_index()}
  end

  # ── Attributes ───────────────────────────────────────────────────────────

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

  # ── Relationship ─────────────────────────────────────────────────────────

  defp add_bulk_action_relationship(dsl_state) do
    if Info.relationship(dsl_state, :bulk_action) do
      dsl_state
    else
      destination = AshBulkDurable.Core.config(:bulk_action_resource)

      if is_nil(destination) do
        raise """
        AshBulkDurable.Core.Resource.Row requires `:bulk_action_resource` to be
        configured before the host resource compiles, e.g.

            config :ash_bulk_durable,
              bulk_action_resource: MyApp.BulkActions.BulkAction,
              row_resource: MyApp.BulkActions.Row
        """
      end

      {:ok, relationship} =
        Transformer.build_entity(Dsl, [:relationships], :belongs_to,
          name: :bulk_action,
          destination: destination,
          allow_nil?: false,
          public?: true,
          attribute_type: :uuid
        )

      Transformer.add_entity(dsl_state, [:relationships], relationship, type: :append)
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

  defp add_bulk_create_action(dsl_state) do
    if Info.action(dsl_state, :create) do
      dsl_state
    else
      accept = [
        :bulk_action_id,
        :row_index,
        :target,
        :input,
        :metadata,
        :resolved_data,
        :status,
        :error,
        :refused
      ]

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :create,
          name: :create,
          primary?: true,
          accept: accept
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_next_pending_chunk_action(dsl_state) do
    if Info.action(dsl_state, :next_pending_chunk) do
      dsl_state
    else
      import Ash.Expr

      bulk_action_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :bulk_action_id,
          type: :uuid,
          allow_nil?: false
        )

      chunk_size_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :chunk_size,
          type: :integer,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter: expr(bulk_action_id == ^arg(:bulk_action_id) and status == :pending)
        )

      prepare =
        Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
          preparation: AshBulkDurable.Core.Resource.Row.Preparations.LimitByChunkSize
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :next_pending_chunk,
          arguments: [bulk_action_id_arg, chunk_size_arg],
          filters: [filter],
          preparations: [prepare]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Phase-2 pagination: the next slice of rows that phase 1 has resolved
  # (`status == :resolved`) but phase 2 hasn't applied yet. Mirror of
  # `:next_pending_chunk` with the status filter flipped — the apply loop
  # reads `:resolved`, the resolve loop reads `:pending`.
  defp add_next_resolved_chunk_action(dsl_state) do
    if Info.action(dsl_state, :next_resolved_chunk) do
      dsl_state
    else
      import Ash.Expr

      bulk_action_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :bulk_action_id,
          type: :uuid,
          allow_nil?: false
        )

      chunk_size_arg =
        Transformer.build_entity!(Dsl, [:actions, :read], :argument,
          name: :chunk_size,
          type: :integer,
          allow_nil?: false
        )

      filter =
        Transformer.build_entity!(Dsl, [:actions, :read], :filter,
          filter: expr(bulk_action_id == ^arg(:bulk_action_id) and status == :resolved)
        )

      prepare =
        Transformer.build_entity!(Dsl, [:actions, :read], :prepare,
          preparation: AshBulkDurable.Core.Resource.Row.Preparations.LimitByChunkSize
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :read,
          name: :next_resolved_chunk,
          arguments: [bulk_action_id_arg, chunk_size_arg],
          filters: [filter],
          preparations: [prepare]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # Per-row phase-1 resolution. `AshBulkDurable.Core.Changes.ResolveRow`
  # resolves the row's references in a `before_transaction` hook (outside
  # the row's transaction), keeps what they resolved to, and flips the row to
  # `:resolved`. The worker drives one `Ash.update(:resolve)` per row inside
  # `Task.async_stream`, so the I/O runs concurrently while each row's tiny
  # write is its own transaction. The chunk's prepared resolvers ride in on
  # the action `context`.
  defp add_resolve_action(dsl_state) do
    if Info.action(dsl_state, :resolve) do
      dsl_state
    else
      change =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.ResolveRow
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :resolve,
          accept: [],
          require_atomic?: false,
          changes: [change]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_forget_resolutions_action(dsl_state) do
    if Info.action(dsl_state, :forget_resolutions) do
      dsl_state
    else
      names_arg =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :names,
          type: {:array, :string},
          allow_nil?: false
        )

      forget =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.ForgetResolutions
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :forget_resolutions,
          accept: [],
          require_atomic?: false,
          arguments: [names_arg],
          changes: [forget]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_mark_succeeded_action(dsl_state) do
    if Info.action(dsl_state, :mark_succeeded) do
      dsl_state
    else
      record_id_arg =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :record_id,
          type: :string,
          allow_nil?: true
        )

      set_status =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: {Ash.Resource.Change.SetAttribute, [attribute: :status, value: :succeeded]}
        )

      set_record_id =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.SetRecordIdFromArg
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :mark_succeeded,
          accept: [],
          require_atomic?: false,
          arguments: [record_id_arg],
          changes: [set_status, set_record_id]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_mark_failed_action(dsl_state) do
    if Info.action(dsl_state, :mark_failed) do
      dsl_state
    else
      error_arg =
        Transformer.build_entity!(Dsl, [:actions, :update], :argument,
          name: :error,
          type: AshBulkDurable.Core.StoredErrors,
          allow_nil?: false
        )

      set_status =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: {Ash.Resource.Change.SetAttribute, [attribute: :status, value: :failed]}
        )

      set_error =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.SetErrorFromArg
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :mark_failed,
          accept: [],
          require_atomic?: false,
          arguments: [error_arg],
          changes: [set_status, set_error]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_run_action(dsl_state) do
    if Info.action(dsl_state, :run) do
      dsl_state
    else
      change =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.RunRow
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :run,
          accept: [],
          require_atomic?: false,
          changes: [change]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  defp add_reopen_with_corrections_action(dsl_state) do
    if Info.action(dsl_state, :reopen_with_corrections) do
      dsl_state
    else
      arguments =
        Enum.map(
          [
            target: :term,
            input: :term,
            shared_input: :term,
            metadata: :map,
            error: AshBulkDurable.Core.StoredErrors
          ],
          fn {name, type} ->
            Transformer.build_entity!(Dsl, [:actions, :update], :argument,
              name: name,
              type: type,
              allow_nil?: true
            )
          end
        )

      apply_change =
        Transformer.build_entity!(Dsl, [:actions, :update], :change,
          change: AshBulkDurable.Core.Changes.ReopenWithCorrections
        )

      {:ok, action} =
        Transformer.build_entity(Dsl, [:actions], :update,
          name: :reopen_with_corrections,
          accept: [],
          require_atomic?: false,
          arguments: arguments,
          changes: [apply_change]
        )

      Transformer.add_entity(dsl_state, [:actions], action, type: :append)
    end
  end

  # ── Postgres ─────────────────────────────────────────────────────────────

  defp add_postgres_reference(dsl_state) do
    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :references])
      |> Enum.find(&(&1.relationship == :bulk_action))

    if existing do
      dsl_state
    else
      {:ok, reference} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :references], :reference,
          relationship: :bulk_action,
          on_delete: :delete,
          on_update: :restrict
        )

      Transformer.add_entity(dsl_state, [:postgres, :references], reference, type: :append)
    end
  end

  # Composite index that fully serves the chunk-pagination reads
  # (`:next_pending_chunk` and `:next_resolved_chunk`): the worker
  # filters on `(bulk_action_id, status)` and sorts by `row_index asc`,
  # then takes `LIMIT chunk_size`. With `row_index` trailing the index,
  # the rows come out already ordered and the sort/limit is an
  # index-served prefix — no extra heap sort per chunk.
  defp add_status_index(dsl_state) do
    fields = [:bulk_action_id, :status, :row_index]

    existing =
      dsl_state
      |> Transformer.get_entities([:postgres, :custom_indexes])
      |> Enum.find(&(&1.fields == fields))

    if existing do
      dsl_state
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          fields: fields
        )

      Transformer.add_entity(dsl_state, [:postgres, :custom_indexes], index, type: :append)
    end
  end
end
