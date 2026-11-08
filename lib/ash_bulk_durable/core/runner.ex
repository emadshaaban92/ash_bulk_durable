defmodule AshBulkDurable.Core.Runner do
  @moduledoc """
  Runs one bulk action's rows. A row is a target and an input: the target
  names the record the row acts on (none for a create, a lookup for an
  update or destroy) and the tenant it acts in; the input is what the action
  receives, as a form sends its params. Any input value, and the target's
  tenant, may be a reference (`AshBulkDurable.Core.Reference`) the resolve
  phase turns into a value before the row is written.

  An input every row shares is stored once, on the bulk action. A row's own
  input replaces it rather than merging into it (`input/2`), so what a row
  ran with is always one input. A shared reference resolves per row, since
  a lookup finds a different record in each tenant.

  A row's `target` is `nil` or a map of:

    * `:lookup` — the filter input finding the record, e.g. `%{code: "C1"}`.
      A key may traverse a relationship (`%{code: "C1", owner: %{code:
      "O1"}}`) to narrow the lookup without naming a tenant.
    * `:tenant` — the tenant the row acts in, a value or a reference;
      without one the row acts in the bulk action's `tenant`.

  The worker drives the two phases through:

    * `settings/3` — what every row of the bulk action shares.
    * `initial_status/2` — the status a row is stored with.
    * `resolve_tenants/2` — phase 1: each row's tenant, a tenant reference
      resolved, so the worker resolves the rows' input tenant by tenant.
    * `references/2` — the input references rows still hold, so the worker
      prepares their resolvers once per chunk and tenant
      (`AshBulkDurable.Core.Reference.prepare/2`).
    * `resolve_references/3` — phase 1: what one row's input references
      resolve to, keyed by input name.
    * `run_row/2` — phase 2: run the action with the row's input in its
      tenant. No transaction is opened; the caller wraps this in one.
  """

  import AshBulkDurable.Core.Reference, only: [is_composite: 1]

  alias AshBulkDurable.Core.{
    BulkActionLock,
    Introspection,
    ManyMatchesError,
    NoMatchError,
    Reference,
    RowTimeoutError,
    StoredTerm,
    UnreadableRowError
  }

  alias AshBulkDurable.Core.Resolver.Context

  require Logger

  defmodule Settings do
    @moduledoc """
    What every row of one bulk action shares: the action, the mode, who runs
    it, the tenant a row naming none acts in, the input a row with none of
    its own runs with, the files staged for it, downloaded to local paths
    and keyed as they were staged, and the bulk action's `pass` they were
    read in.
    """

    @enforce_keys [:resource, :action_name, :action_type, :scope]
    defstruct [
      :resource,
      :action_name,
      :action_type,
      :mode,
      :scope,
      tenant: nil,
      input: nil,
      staged_files: %{},
      pass: 0
    ]

    @type t :: %__MODULE__{
            resource: module(),
            action_name: atom(),
            action_type: :create | :update | :destroy,
            mode: :per_row | :all_or_nothing,
            scope: term(),
            tenant: term(),
            input: map() | nil,
            staged_files: %{optional(term()) => Path.t()},
            pass: non_neg_integer()
          }
  end

  @doc "The settings `bulk_action` runs its rows with, as `scope`."
  def settings(bulk_action, scope, staged_files) do
    %Settings{
      resource: Introspection.resource(bulk_action),
      action_name: Introspection.action(bulk_action).name,
      action_type: Introspection.action_type(bulk_action),
      mode: bulk_action.mode,
      scope: scope,
      tenant: bulk_action.tenant,
      input: bulk_action.input,
      staged_files: staged_files,
      pass: bulk_action.pass
    }
  end

  @doc "The tenant `scope` acts in, `nil` for one that names none."
  def scope_tenant(nil), do: nil

  def scope_tenant(scope) do
    case Ash.Scope.ToOpts.get_tenant(scope) do
      {:ok, tenant} -> tenant
      _none -> nil
    end
  rescue
    Protocol.UndefinedError -> nil
  end

  @doc "What is stored for an input: `nil`, when there is none."
  def stored_input(input) when map_size(input) == 0, do: nil
  def stored_input(input), do: input

  @doc "What `row` runs with: its own input, or else `shared_input`."
  def input(%{input: %StoredTerm.Unreadable{}}, _shared_input), do: %{}
  def input(%{input: own}, _shared_input) when map_size(own) > 0, do: own
  def input(_row, nil), do: %{}
  def input(_row, shared_input), do: shared_input

  @doc """
  The status a row is stored with: `:failed` when its caller already
  refused it, `:pending` while it holds a reference to resolve, in its own
  input or the `shared_input` it runs with, otherwise `:resolved`, so the
  resolve phase never reads it.
  """
  def initial_status(row, shared_input) do
    cond do
      not is_nil(Map.get(row, :error)) -> :failed
      references?(row, shared_input) -> :pending
      true -> :resolved
    end
  end

  defp references?(row, shared_input) do
    Reference.reference?(target_tenant(Map.get(row, :target))) or
      row
      |> input(shared_input)
      |> Enum.any?(fn {_key, value} -> Reference.reference?(value) end)
  end

  @doc """
  Whether `target` finds its record by an identity, so correcting it can
  change the lookup. One found by its primary key is the record selected,
  unless its caller named that key the identity, as a value someone typed.
  """
  def found_by_identity?(%{identity: :primary_key}, _resource), do: true

  def found_by_identity?(%{lookup: %{} = lookup}, resource) do
    Enum.sort(Map.keys(lookup)) != Enum.sort(Ash.Resource.Info.primary_key(resource))
  end

  def found_by_identity?(_target, _resource), do: false

  @doc "The tenant `row` acts in: its target's, once resolved, or the bulk action's."
  def tenant(%Settings{tenant: default}, row) do
    case target_tenant(row.target) do
      nil ->
        default

      tenant ->
        if Reference.reference?(tenant), do: row.resolved_tenant, else: tenant
    end
  end

  @doc """
  Each row of `rows` paired with its tenant, `{:ok, tenant}`, or with the
  error its tenant reference resolved to. A tenant is looked up in the bulk
  action's own tenant. `{:error, error}` when the tenants' resolvers can't
  be prepared.
  """
  def resolve_tenants(%Settings{} = settings, rows) do
    context = resolver_context(settings)
    references = rows |> Enum.map(&unresolved_tenant/1) |> Enum.reject(&is_nil/1)

    case Reference.prepare(references, context) do
      {:ok, resolvers} ->
        try do
          {:ok, Enum.map(rows, &{&1, row_tenant(settings, &1, resolvers, context)})}
        after
          Reference.finish(resolvers)
        end

      {:error, error, resolvers} ->
        Reference.finish(resolvers)
        {:error, error}
    end
  end

  defp row_tenant(settings, row, resolvers, context) do
    case unresolved_tenant(row) do
      nil -> {:ok, tenant(settings, row)}
      reference -> resolve(:tenant, reference, resolvers, context)
    end
  end

  @doc "The target's tenant reference, when the resolve phase has yet to resolve it."
  def unresolved_tenant(%{resolved_tenant: nil, target: target}) do
    tenant = target_tenant(target)
    if Reference.reference?(tenant), do: tenant
  end

  def unresolved_tenant(_row), do: nil

  defp target_tenant(%{tenant: tenant}), do: tenant
  defp target_tenant(_target), do: nil

  @doc """
  The references `rows` hold in input values not yet resolved, for the
  worker to prepare their resolvers once for all of them.
  """
  def references(%Settings{} = settings, rows) do
    Enum.flat_map(rows, fn row ->
      settings |> unresolved_references(row) |> Enum.map(fn {_key, reference} -> reference end)
    end)
  end

  @doc """
  Phase-1 per-row resolution: what the row's input references resolve to,
  keyed by **string** input name, the form `resolved_data` stores after the
  JSONB round-trip.

  Inputs already in the row's `resolved_data` are skipped, so a resume or a
  corrected row resolves only what it dropped. `settings` carry the row's
  tenant; `resolvers` are those `AshBulkDurable.Core.Reference.prepare/2`
  readied for its chunk. Returns `{:ok, resolutions}`, or `{:error, error}`
  on the first reference that can't be resolved.
  """
  def resolve_references(%Settings{} = settings, row, resolvers) do
    if StoredTerm.unreadable?(row),
      do: {:error, %UnreadableRowError{}},
      else: resolve_input(settings, row, resolvers)
  end

  defp resolve_input(settings, row, resolvers) do
    context = resolver_context(settings)

    settings
    |> unresolved_references(row)
    |> Enum.reduce_while({:ok, %{}}, fn {key, reference}, {:ok, acc} ->
      case resolve(key, reference, resolvers, context) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, to_string(key), value)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  What `rows` keep that their resolvers say can no longer be used, as `{row,
  names}`, a resolver asked once for each tenant's values. The resolvers'
  callback: `c:AshBulkDurable.Core.Resolver.lost/2`.
  """
  def lost_resolutions(%Settings{} = settings, rows) do
    by_id = Map.new(rows, &{&1.id, &1})

    rows
    |> Enum.flat_map(&kept_by_resolvers(settings, &1))
    |> Enum.group_by(fn {row, _name, module, _value} -> {module, tenant(settings, row)} end)
    |> Enum.flat_map(fn {{module, tenant}, kept} ->
      context = resolver_context(%{settings | tenant: tenant})
      values = Enum.map(kept, fn {_row, _name, _module, value} -> value end)
      lost = module |> Reference.lost(values, context) |> MapSet.new()

      Enum.filter(kept, fn {_row, _name, _module, value} -> value in lost end)
    end)
    |> Enum.group_by(fn {row, _name, _module, _value} -> row.id end, &elem(&1, 1))
    |> Enum.map(fn {id, names} -> {Map.fetch!(by_id, id), names} end)
  end

  defp kept_by_resolvers(settings, row) do
    resolved_data = row.resolved_data

    for {key, {:resolve, module, _args}} <- input(row, settings.input),
        name = to_string(key),
        is_map_key(resolved_data, name),
        do: {row, name, module, Map.fetch!(resolved_data, name)}
  end

  @doc "Whether `row` has a resolver left to run, in its input or its tenant."
  def resolver_pending?(%Settings{} = settings, row) do
    Reference.resolver?(unresolved_tenant(row)) or
      settings
      |> unresolved_references(row)
      |> Enum.any?(fn {_key, reference} -> Reference.resolver?(reference) end)
  end

  @doc "What a resolver may know of the bulk action `settings` describe."
  def resolver_context(%Settings{} = settings) do
    %Context{scope: settings.scope, tenant: settings.tenant, staged_files: settings.staged_files}
  end

  @doc """
  Phase-2 per-row apply: build the changeset from the row's input, its
  references replaced by what they resolved to, and run the action in the
  row's tenant. No transaction is opened; the caller wraps this in one.

  Returns `{:ok, record}` on success so the worker can write its primary key
  to `Row.record_id` inside the same transaction.
  """
  def run_row(%Settings{} = settings, row) do
    if StoredTerm.unreadable?(row) do
      {:error, %UnreadableRowError{}}
    else
      settings = %{settings | tenant: tenant(settings, row)}

      case build_changeset(settings, row) do
        {:ok, changeset} -> run_action(settings.action_type, changeset)
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  What a raise while running `row` fails it with. Logged here because the row
  keeps only the error: nothing else tells anyone the code raised.
  """
  def row_raised(exception, stacktrace, row) do
    Logger.error(
      "bulk action #{row.bulk_action_id} row #{row.row_index} raised: " <>
        Exception.format(:error, exception, stacktrace)
    )

    {:error, exception}
  end

  @doc "What a row whose resolution outran `timeout` fails with, logged as a raise is."
  def row_timed_out(timeout, row) do
    Logger.error(
      "bulk action #{row.bulk_action_id} row #{row.row_index} took longer than #{timeout}ms to resolve"
    )

    %RowTimeoutError{timeout: timeout}
  end

  # ---- References ----------------------------------------------------------

  defp unresolved_references(%Settings{input: shared_input}, row) do
    resolved_data = row.resolved_data || %{}

    for {key, value} <- input(row, shared_input),
        Reference.reference?(value),
        not is_map_key(resolved_data, to_string(key)),
        do: {key, value}
  end

  defp resolve(key, reference, resolvers, context) do
    case Reference.resolve(reference, resolvers, context) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> {:error, no_match(key, reference)}
      {:error, :ambiguous} -> {:error, many_matches(key, reference)}
      {:error, error} -> {:error, error}
    end
  end

  defp no_match(key, {:lookup, resource, identity, values}),
    do: no_match(key, {:lookup, resource, identity, values, []})

  defp no_match(key, {:lookup, resource, identity, values, _opts}),
    do: %NoMatchError{field: key, resource: resource, criteria: criteria(identity, values)}

  defp no_match(key, {:resolve, _module, _args}), do: %NoMatchError{field: key}

  defp many_matches(key, {:lookup, resource, identity, values}),
    do: many_matches(key, {:lookup, resource, identity, values, []})

  defp many_matches(key, {:lookup, resource, identity, values, _opts}),
    do: %ManyMatchesError{field: key, resource: resource, criteria: criteria(identity, values)}

  defp many_matches(key, {:resolve, _module, _args}), do: %ManyMatchesError{field: key}

  # Every key/value pair the caller supplied shows up, pinpointing which one
  # didn't match.
  defp criteria(_identity, composite) when is_composite(composite), do: composite
  defp criteria(identity, value), do: %{identity => value}

  # ---- Per-row action -------------------------------------------------------

  # Name the action explicitly: `Ash.create`/`Ash.update` on an invalid
  # changeset fall back to the resource's *primary* action — which a resource
  # with only named actions lacks, so the bare form raises and crashes the
  # bulk action instead of failing just that row.
  defp run_action(:create, changeset),
    do: Ash.create(changeset, %{}, action: action_name(changeset))

  defp run_action(:update, changeset),
    do: Ash.update(changeset, %{}, action: action_name(changeset))

  # The destroyed record comes back so the row can keep its id.
  defp run_action(:destroy, changeset),
    do: Ash.destroy(changeset, action: action_name(changeset), return_destroyed?: true)

  defp action_name(%{action: %{name: name}}), do: name

  defp build_changeset(%Settings{action_type: :create} = settings, row) do
    {params, written} = params(settings, row)

    changeset =
      settings.resource
      |> Ash.Changeset.for_create(settings.action_name, params, changeset_opts(settings, row))
      |> after_write(written, resolver_context(settings))

    {:ok, changeset}
  end

  defp build_changeset(%Settings{action_type: :update} = settings, row) do
    with {:ok, record} <- read_target(settings, row) do
      {params, written} = params(settings, row)

      changeset =
        record
        |> Ash.Changeset.for_update(settings.action_name, params, changeset_opts(settings, row))
        |> after_write(written, resolver_context(settings))

      {:ok, changeset}
    end
  end

  defp build_changeset(%Settings{action_type: :destroy} = settings, row) do
    with {:ok, record} <- read_target(settings, row) do
      {params, written} = params(settings, row)

      changeset =
        record
        |> Ash.Changeset.for_destroy(settings.action_name, params, changeset_opts(settings, row))
        |> after_write(written, resolver_context(settings))

      {:ok, changeset}
    end
  end

  # The row's input with each reference replaced by what it resolved to, and
  # the resolved references whose resolver wants the written record.
  defp params(%Settings{input: shared_input}, row) do
    resolved_data = row.resolved_data || %{}

    row
    |> input(shared_input)
    |> Enum.reduce({%{}, []}, fn {key, value}, {params, written} ->
      if Reference.reference?(value) do
        resolved = Map.fetch!(resolved_data, to_string(key))
        {Map.put(params, key, resolved), [{value, resolved} | written]}
      else
        {Map.put(params, key, value), written}
      end
    end)
  end

  defp changeset_opts(settings, row) do
    [scope: settings.scope, tenant: settings.tenant, context: changeset_context(settings, row)]
  end

  defp after_write(changeset, [], _context), do: changeset

  defp after_write(changeset, written, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Enum.reduce_while(written, {:ok, record}, &hand_written(&1, &2, record, context))
    end)
  end

  defp hand_written({reference, resolved}, ok, record, context) do
    case Reference.after_write(reference, record, resolved, context) do
      :ok -> {:cont, ok}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp read_target(settings, %{target: %{lookup: %{} = lookup}}) do
    if can_name_a_record?(settings.resource, lookup),
      do: read_lookup(settings, lookup),
      else: {:error, not_found(settings, lookup)}
  end

  defp read_target(settings, _row), do: {:error, not_found(settings, %{})}

  defp read_lookup(settings, lookup) do
    read_action = Ash.Resource.Info.primary_action!(settings.resource, :read).name
    opts = [scope: settings.scope, tenant: settings.tenant]

    case settings.resource
         |> Ash.Query.for_read(read_action, %{}, opts)
         |> Ash.Query.filter_input(lookup)
         |> BulkActionLock.pin()
         |> Ash.read_one(opts) do
      {:ok, %{} = record} -> {:ok, record}
      {:ok, nil} -> {:error, not_found(settings, lookup)}
      {:error, error} -> {:error, error}
    end
  end

  # A value that can't be its key's type names no record. Reading it would
  # throw out of the chunk's transaction, past the row's rescue.
  defp can_name_a_record?(resource, lookup) do
    Enum.all?(lookup, fn {key, value} ->
      case Ash.Resource.Info.attribute(resource, key) do
        nil -> true
        attribute -> castable?(attribute, value)
      end
    end)
  end

  defp castable?(%{type: type, constraints: constraints}, value) do
    case Ash.Type.cast_input(type, value, constraints) do
      {:ok, cast} -> not is_nil(cast)
      _uncastable -> false
    end
  end

  # Names the values the row looked up, not a clause through a relationship
  # (it only narrows the lookup), so each is reported against the input the
  # reader can correct.
  defp not_found(settings, lookup) do
    Ash.Error.Query.NotFound.exception(
      primary_key: Map.reject(lookup, fn {_key, value} -> is_composite(value) end),
      resource: settings.resource
    )
  end

  # The mode lets an action whose invariant needs one mode refuse the other.
  # The row index traces a failed changeset surfacing from a bulk error back
  # to its row (the worker names it in the bulk action's terminal result).
  defp changeset_context(settings, row) do
    %{
      action_source: AshBulkDurable.Core.action_source(),
      ash_bulk_durable: %{mode: settings.mode, row_index: row.row_index}
    }
  end
end
