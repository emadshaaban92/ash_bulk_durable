defmodule ExampleWeb.Bulk.ViewOptions do
  alias AshBulkDurable.Sheet
  alias AshBulkDurable.Sheet.{Field, Mapping}
  alias ExampleWeb.Bulk.Utils

  defstruct [
    :scope,
    :allowed_resources,
    :resource,
    :action,
    :identity,
    mapping: %{},
    rel_identities: %{}
  ]

  def from_url_params(params, scope) do
    from_url_params(params, scope, allowed_resources(scope))
  end

  def from_url_params(params, scope, allowed_resources) do
    %__MODULE__{
      scope: scope,
      allowed_resources: allowed_resources
    }
    |> set_resource(params |> Map.get("resource"))
    |> set_action(params |> Map.get("action"))
    |> set_identity(params |> Map.get("identity"))
    |> set_mapping(params |> Map.get("mapping", %{}))
    |> set_rel_identities(params |> Map.get("rel_identities", %{}))
  end

  def allowed_resources(scope) do
    ExampleWeb.Bulk.config(:resources, [])
    |> Enum.reject(&(Ash.Resource.Info.identities(&1) == []))
    |> Enum.filter(fn resource -> can?({resource, :read}, scope) end)
    |> Enum.flat_map(fn resource ->
      Ash.Resource.Info.actions(resource)
      |> Enum.filter(fn action ->
        action.type in [:create, :update, :destroy] and can?({resource, action}, scope)
      end)
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&{resource, &1})
    end)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.update(acc, k, [v], &(&1 ++ [v]))
    end)
  end

  def set_resource(options, nil) do
    %{options | resource: nil, action: nil, identity: nil} |> prune_mapping()
  end

  def set_resource(options, resource_name) do
    resource =
      with name when not is_nil(name) <- safe_existing_atom(resource_name) do
        options.allowed_resources
        |> Map.keys()
        |> Enum.find(&(Ash.Resource.Info.short_name(&1) == name))
      end

    %{options | resource: resource, action: nil, identity: nil} |> prune_mapping()
  end

  def set_action(options, nil) do
    %{options | action: nil, identity: nil} |> prune_mapping()
  end

  # A handcrafted `/bulk?resource=X&action=Y` URL where `X` doesn't resolve
  # for the actor leaves `resource` nil (via `set_resource`'s nil guard) but
  # still carries an `action` param. Without this clause `Map.get(allowed_
  # resources, nil)` returns nil and the `Enum.find` below crashes. Mirror
  # the `%{resource: nil}` clause in `actions_select_opts/1`.
  def set_action(%{resource: nil} = options, _action_name) do
    %{options | action: nil, identity: nil} |> prune_mapping()
  end

  def set_action(options, action_name) do
    action =
      with name when not is_nil(name) <- safe_existing_atom(action_name) do
        options.allowed_resources
        |> Map.get(options.resource)
        |> Enum.find(&(&1.name == name))
      end

    %{options | action: action, identity: nil} |> prune_mapping()
  end

  def set_identity(options, nil) do
    %{options | identity: nil} |> prune_mapping()
  end

  def set_identity(%{resource: nil} = options, _identity_name) do
    %{options | identity: nil} |> prune_mapping()
  end

  def set_identity(options, identity_name) do
    identity =
      with name when not is_nil(name) <- safe_existing_atom(identity_name) do
        Mapping.lookup_identity(options.resource, name)
      end

    %{options | identity: identity} |> prune_mapping()
  end

  # URL params are user-controllable strings; a handcrafted `?resource=nope`
  # used to crash the LV when `String.to_existing_atom/1` raised
  # `ArgumentError`. Returning `nil` instead lets the upstream `Enum.find`
  # / `Map.get` resolve to nil and the URL setter reset cleanly.
  defp safe_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp prune_mapping(options) do
    fields = fields(options)
    field_names = fields |> Enum.map(& &1.field.name) |> MapSet.new()

    rel_names =
      fields
      |> Enum.filter(&match?(%Field{field: %Ash.Resource.Relationships.BelongsTo{}}, &1))
      |> Enum.map(& &1.field.name)
      |> MapSet.new()

    %{
      options
      | mapping: Map.filter(options.mapping, fn {k, _} -> MapSet.member?(field_names, k) end),
        rel_identities:
          Map.filter(options.rel_identities, fn {k, _} -> MapSet.member?(rel_names, k) end)
    }
  end

  def set_mapping(options, mapping) do
    Enum.reduce(mapping, options, fn
      {field, %{} = sub_map}, acc ->
        Enum.reduce(sub_map, acc, fn {sub_key, csv_key}, acc2 ->
          update_mapping(acc2, field, sub_key, csv_key)
        end)

      {field, csv_key}, acc ->
        update_mapping(acc, field, csv_key)
    end)
  end

  def update_mapping(options, field, csv_key) when is_atom(field) do
    mapping = Map.put(options.mapping, field, csv_key)
    %{options | mapping: mapping}
  end

  def update_mapping(options, field, csv_key) when is_binary(field) do
    case safe_existing_atom(field) do
      nil -> options
      atom -> update_mapping(options, atom, csv_key)
    end
  end

  # Composite-key form: mapping[field] is a nested map of {sub_key => csv_col}.
  def update_mapping(options, field, sub_key, csv_key)
      when is_atom(field) and is_atom(sub_key) do
    sub_map =
      options.mapping
      |> Map.get(field, %{})
      |> ensure_sub_map()
      |> Map.put(sub_key, csv_key)

    mapping = Map.put(options.mapping, field, sub_map)
    %{options | mapping: mapping}
  end

  def update_mapping(options, field, sub_key, csv_key) when is_binary(field) do
    case safe_existing_atom(field) do
      nil -> options
      atom -> update_mapping(options, atom, sub_key, csv_key)
    end
  end

  def update_mapping(options, field, sub_key, csv_key) when is_binary(sub_key) do
    case safe_existing_atom(sub_key) do
      nil -> options
      atom -> update_mapping(options, field, atom, csv_key)
    end
  end

  # Existing mapping might be a string (left over from a single-key identity);
  # composite forms expect a map, so reset to %{} in that case.
  defp ensure_sub_map(%{} = sub_map) when not is_struct(sub_map), do: sub_map
  defp ensure_sub_map(_), do: %{}

  def set_rel_identities(options, rel_identities) do
    Enum.reduce(rel_identities, options, &update_rel_identities(&2, elem(&1, 0), elem(&1, 1)))
  end

  def update_rel_identities(options, field, identity_name) when is_atom(field) do
    rel_identities =
      case identity_name do
        empty when empty in ["", nil] ->
          Map.delete(options.rel_identities, field)

        name when is_atom(name) ->
          Map.put(options.rel_identities, field, name)

        name when is_binary(name) ->
          case safe_existing_atom(name) do
            nil -> Map.delete(options.rel_identities, field)
            atom -> Map.put(options.rel_identities, field, atom)
          end
      end

    # The new identity may change the *shape* of the mapping for this field
    # (single string for 1-key identities, map for composite). Drop the
    # existing mapping value only when the shape no longer fits — same-shape
    # transitions (e.g. swapping between two single-key identities) keep
    # whatever the user already picked.
    mapping = maybe_reshape_mapping(options, field, rel_identities)

    %{options | rel_identities: rel_identities, mapping: mapping}
  end

  def update_rel_identities(options, field, identity_name) when is_binary(field) do
    case safe_existing_atom(field) do
      nil -> options
      atom -> update_rel_identities(options, atom, identity_name)
    end
  end

  defp maybe_reshape_mapping(options, field, new_rel_identities) do
    composite_now? = match?(%{}, Map.get(options.mapping, field))

    composite_after? =
      composite_identity?(options.resource, field, Map.get(new_rel_identities, field))

    if composite_now? == composite_after? do
      options.mapping
    else
      Map.delete(options.mapping, field)
    end
  end

  defp composite_identity?(_resource, _field, nil), do: false

  defp composite_identity?(resource, field, identity_name) do
    with relationship when not is_nil(relationship) <-
           Ash.Resource.Info.relationship(resource, field),
         %{keys: keys} <-
           Ash.Resource.Info.identity(relationship.destination, identity_name) do
      length(keys) > 1
    else
      _ -> false
    end
  end

  def to_url_params(options) do
    %{}
    |> maybe_put_resource(options)
    |> maybe_put_action(options)
    |> maybe_put_identity(options)
    |> maybe_put_mapping(options)
    |> maybe_put_rel_identities(options)
  end

  defp maybe_put_resource(params, %{resource: nil}), do: params

  defp maybe_put_resource(params, %{resource: resource}) do
    Map.put(params, "resource", Ash.Resource.Info.short_name(resource))
  end

  defp maybe_put_action(params, %{action: nil}), do: params

  defp maybe_put_action(params, %{action: action}) do
    Map.put(params, "action", action.name)
  end

  defp maybe_put_identity(params, %{identity: nil}), do: params

  defp maybe_put_identity(params, %{identity: identity}) do
    Map.put(params, "identity", identity.name)
  end

  defp maybe_put_mapping(params, %{mapping: mapping}) when mapping == %{},
    do: params

  defp maybe_put_mapping(params, %{mapping: %{} = mapping}) do
    mapping
    |> Enum.flat_map(fn
      {_field, value} when value in [nil, ""] ->
        []

      {field, %{} = sub_map} ->
        sub_map
        |> Map.reject(fn {_, v} -> v in [nil, ""] end)
        |> Enum.map(fn {sub_key, csv_key} ->
          {"mapping[#{field}][#{sub_key}]", csv_key}
        end)

      {field, csv_key} ->
        [{"mapping[#{field}]", csv_key}]
    end)
    |> Map.new()
    |> Map.merge(params)
  end

  defp maybe_put_rel_identities(params, %{rel_identities: rel_identities})
       when rel_identities == %{},
       do: params

  defp maybe_put_rel_identities(params, %{rel_identities: %{} = rel_identities}) do
    rel_identities
    |> Map.filter(&(elem(&1, 1) not in [nil, ""]))
    |> Enum.into(%{}, fn {key, value} -> {"rel_identities[#{to_string(key)}]", value} end)
    |> Map.merge(params)
  end

  def resource_name(%{resource: nil}), do: nil
  def resource_name(%{resource: resource}), do: Ash.Resource.Info.short_name(resource)

  def resources_select_opts(options) do
    opts =
      options.allowed_resources
      |> Map.keys()
      |> Enum.map(&Ash.Resource.Info.short_name/1)
      |> Enum.sort()
      |> Enum.map(&{&1 |> Utils.humanize(), &1})

    [{nil, ""} | opts]
  end

  def action_name(%{action: nil}), do: nil
  def action_name(%{action: action}), do: action.name

  def actions_select_opts(%{resource: nil}), do: [{nil, ""}]

  def actions_select_opts(options) do
    opts =
      options.allowed_resources
      |> Map.get(options.resource)
      |> Enum.map(& &1.name)
      |> Enum.sort()
      |> Enum.map(&{ExampleWeb.Bulk.Utils.field_label(&1, options.resource), &1})

    [{nil, ""} | opts]
  end

  def identity_name(%{identity: nil}), do: nil
  def identity_name(%{identity: identity}), do: identity.name

  def identities_select_opts(%{resource: nil}), do: [{nil, ""}]

  def identities_select_opts(options) do
    opts =
      options.resource
      |> Mapping.lookup_identities()
      |> Enum.map(& &1.name)
      |> Enum.sort()
      |> Enum.map(&{ExampleWeb.Bulk.Utils.field_label(&1, options.resource), &1})

    [{nil, ""} | opts]
  end

  def mapping_value(%{mapping: mapping}, field) when is_atom(field) do
    Map.get(mapping, field)
  end

  def mapping_value(%{mapping: mapping}, field) when is_binary(field) do
    case safe_existing_atom(field) do
      nil -> nil
      atom -> Map.get(mapping, atom)
    end
  end

  # Composite-key lookup: pulls the CSV column mapped to a specific identity
  # sub-key (e.g. `mapping_value(opts, :shelf, :owner_id)` for the owner_id
  # half of a {owner_id, code} identity).
  def mapping_value(%{mapping: mapping}, field, sub_key)
      when is_atom(field) and is_atom(sub_key) do
    case Map.get(mapping, field) do
      %{} = sub_map -> Map.get(sub_map, sub_key)
      _ -> nil
    end
  end

  def mapping_value(options, field, sub_key) when is_binary(field) do
    case safe_existing_atom(field) do
      nil -> nil
      atom -> mapping_value(options, atom, sub_key)
    end
  end

  def mapping_value(options, field, sub_key) when is_binary(sub_key) do
    case safe_existing_atom(sub_key) do
      nil -> nil
      atom -> mapping_value(options, field, atom)
    end
  end

  @doc """
  Returns the list of identity keys for a `belongs_to` field iff its chosen
  identity has more than one key (composite). Returns `nil` for single-key
  identities, unset identities, or non-relationship fields — callers fall
  back to the single-column rendering in those cases.
  """
  def composite_identity_keys(options, field_atom) when is_atom(field_atom) do
    with identity_name when is_atom(identity_name) and not is_nil(identity_name) <-
           rel_identities_value(options, field_atom),
         relationship when not is_nil(relationship) <-
           Ash.Resource.Info.relationship(options.resource, field_atom),
         %{keys: keys} when length(keys) > 1 <-
           Ash.Resource.Info.identity(relationship.destination, identity_name) do
      keys
    else
      _ -> nil
    end
  end

  def rel_identities_value(%{rel_identities: rel_identities}, field) when is_atom(field) do
    Map.get(rel_identities, field)
  end

  def rel_identities_value(%{rel_identities: rel_identities}, field) when is_binary(field) do
    case safe_existing_atom(field) do
      nil -> nil
      atom -> Map.get(rel_identities, atom)
    end
  end

  def upload_ready?(%{resource: nil}), do: false
  def upload_ready?(%{action: nil}), do: false
  def upload_ready?(%{action: %{type: :create}}), do: true
  def upload_ready?(%{identity: nil}), do: false
  def upload_ready?(_options), do: true

  def fields(options) when options.resource != nil and options.action != nil do
    keys = identity_keys(options)

    relationships =
      options.resource
      |> Ash.Resource.Info.relationships()
      |> Enum.reject(&(&1.source_attribute in keys))

    options
    |> identity_fields(options)
    |> Enum.concat(Ash.Resource.Info.action_inputs(options.resource, options.action.name))
    |> Enum.filter(&is_atom/1)
    |> Enum.reject(&(&1 |> to_string |> String.ends_with?("_ids")))
    |> Enum.uniq()
    |> Enum.map(fn field ->
      Enum.find(relationships, &(&1.source_attribute == field)) || field
    end)
    |> Enum.map(fn
      field when is_atom(field) ->
        Enum.find(options.action.arguments, &(&1.name == field)) || field

      field ->
        field
    end)
    |> Enum.map(fn
      field when is_atom(field) ->
        Ash.Resource.Info.attribute(options.resource, field) || field

      field ->
        field
    end)
    |> Enum.map(&%Field{field: &1, resource: options.resource, action: options.action})
    |> Enum.filter(&claimed_by_a_handler?/1)
  end

  def fields(_options), do: []

  # A key finds the record by its own value, so it stays that value's column
  # rather than becoming a relationship looked up by another identity.
  defp identity_keys(%{identity: %{keys: keys}}), do: keys
  defp identity_keys(_options), do: []

  defp claimed_by_a_handler?(field) do
    Sheet.handler_for(field) != nil
  end

  defp identity_fields(_options, %{identity: nil}), do: []

  defp identity_fields(options, %{identity: %{keys: keys}}) do
    keys ++ tenant_identity_extension(options)
  end

  # Cross-tenant mode: append the multi-tenancy source attribute (e.g.
  # `:owner_id`) as a synthetic identity key. `fields/1` then replaces it
  # with the matching `belongs_to` relationship struct, so the Owner card
  # gets rendered exactly the way composite-key BelongsTo cards do.
  defp tenant_identity_extension(options) do
    case tenant_attribute(options) do
      nil -> []
      attr -> [attr]
    end
  end

  @doc """
  True when the bulk page should run in cross-tenant mode: the actor has
  no tenant in scope, the resource opts into global multi-tenancy
  (`global?: true`), the chosen action is an update, and the chosen
  identity is unique *per tenant* (not `all_tenants?: true`). When true,
  a Owner card surfaces in the mapping grid and the per-row read filter
  is extended with the owner criterion via relationship traversal.
  """
  def cross_tenant?(%__MODULE__{resource: nil}), do: false
  def cross_tenant?(%__MODULE__{action: nil}), do: false
  def cross_tenant?(%__MODULE__{identity: nil}), do: false
  def cross_tenant?(%__MODULE__{action: %{type: type}}) when type != :update, do: false

  def cross_tenant?(%__MODULE__{
        scope: scope,
        resource: resource,
        identity: identity
      }) do
    is_nil(scope_tenant(scope)) and
      Ash.Resource.Info.multitenancy_strategy(resource) == :attribute and
      Ash.Resource.Info.multitenancy_global?(resource) and
      not Map.get(identity, :all_tenants?, false)
  end

  defp scope_tenant(nil), do: nil

  defp scope_tenant(scope) do
    case Ash.Scope.ToOpts.get_tenant(scope) do
      {:ok, tenant} -> tenant
      _ -> nil
    end
  rescue
    Protocol.UndefinedError -> nil
  end

  @doc """
  Multi-tenancy source attribute (e.g. `:owner_id`) when in cross-tenant
  mode, `nil` otherwise. Used as the synthetic identity key that gets
  rendered as a Owner BelongsTo card.
  """
  def tenant_attribute(%__MODULE__{} = options) do
    if cross_tenant?(options) do
      Ash.Resource.Info.multitenancy_attribute(options.resource)
    end
  end

  @doc """
  The `belongs_to` relationship whose `source_attribute` is the
  multi-tenancy attribute — the Owner card's underlying field. `nil`
  outside cross-tenant mode or when the resource doesn't declare a
  matching relationship.
  """
  def tenant_rel(%__MODULE__{} = options) do
    case tenant_attribute(options) do
      nil ->
        nil

      attr ->
        Ash.Resource.Info.relationships(options.resource)
        |> Enum.find(&match?(%Ash.Resource.Relationships.BelongsTo{source_attribute: ^attr}, &1))
    end
  end

  @doc """
  The options the chosen identity and columns give a sheet's verb
  (`AshBulkDurable.bulk_create/4` and its siblings): `:identity` and
  `:mapping`.
  """
  def sheet_options(%__MODULE__{} = options) do
    [
      identity: options.identity && options.identity.name,
      mapping: [
        columns: options.mapping,
        rel_identities: options.rel_identities,
        tenant_mapping: tenant_mapping_for_persist(options)
      ]
    ]
  end

  @doc """
  Builds the mapping's `tenant_mapping` for cross-tenant mode, or `nil`
  otherwise. Returns `nil` when the user hasn't completed the Owner card
  yet (no identity chosen or no CSV column mapped).

  Shape: `%{rel_name: :owner, identity: :code, csv_col: "owner_code"}`.
  """
  def tenant_mapping_for_persist(%__MODULE__{} = options) do
    case tenant_rel(options) do
      nil ->
        nil

      rel ->
        identity = Map.get(options.rel_identities, rel.name)
        csv_col = Map.get(options.mapping, rel.name)

        if not is_nil(identity) and is_binary(csv_col) and csv_col != "" do
          %{rel_name: rel.name, identity: identity, csv_col: csv_col}
        end
    end
  end

  def rel_identities_select_opts(%Field{field: relationship}) do
    opts =
      relationship.destination
      |> Ash.Resource.Info.identities()
      |> Enum.map(& &1.name)
      |> Enum.sort()
      |> Enum.map(&{ExampleWeb.Bulk.Utils.field_label(&1, relationship.destination), &1})

    [{nil, ""} | opts]
  end

  @doc """
  True when the field is a `belongs_to` relationship — drives the rendering
  of the per-field "Lookup by" identity dropdown.
  """
  def belongs_to?(%Field{field: %Ash.Resource.Relationships.BelongsTo{}}), do: true
  def belongs_to?(%Field{}), do: false

  @doc """
  True when the field participates in the row lookup (identity key or the
  cross-tenant Owner card) rather than carrying a new value to apply.
  Used by the mapping panel to split "look up by" cards from "update
  these" cards on `:update` actions.
  """
  def identity_field?(%Field{field: f}, %__MODULE__{} = options) do
    identity_key?(options, f.name)
  end

  @doc """
  Splits the field list into `{identity_fields, other_fields}` so the
  mapping panel can render them in two labelled sections. For `:create`
  actions or before the user picks an identity, `identity_fields` is
  empty and the panel falls back to a single ungrouped grid.
  """
  def partition_fields(%__MODULE__{} = options) do
    options
    |> fields()
    |> Enum.split_with(&identity_field?(&1, options))
  end

  @doc """
  Must the user provide a mapping for this field given the current
  action/identity?

  Rules, top-down:

    1. Identity keys (used to look up the row on update/destroy) are
       always required — without them the action can't run.
    2. A non-nil `:default` on the field means Ash will fill the value in
       if the user omits it, so the mapping is optional regardless of
       `allow_nil?`. Applied uniformly to attributes and arguments.
    3. Action arguments follow their own `allow_nil?` — they are explicit
       inputs declared by the action, meaningful for any action type.
    4. For `:create` actions, an attribute's `allow_nil?` is the right
       proxy for "user must supply" (no existing row, so the DB
       constraint shows up at insert time).
    5. For `:update` / `:destroy`, attributes are optional — the existing
       row already satisfies non-nullability and the user is mapping
       only the subset they want to change.
  """
  def required?(%Field{} = bf, options) do
    cond do
      identity_key?(options, bf.field.name) -> true
      has_default?(bf.field) -> false
      argument?(bf.field) -> not bf.field.allow_nil?
      options.action.type == :create -> not bf.field.allow_nil?
      true -> false
    end
  end

  defp identity_key?(%__MODULE__{identity: %{keys: keys}} = options, name) do
    name in keys or tenant_card_name?(options, name)
  end

  defp identity_key?(_, _), do: false

  # In cross-tenant mode, the Owner card is required even though it isn't
  # part of the chosen identity's `keys`. Match by the relationship name
  # (e.g. `:owner`) because that's what reaches `required?/1` via the
  # field card's `field.name`.
  defp tenant_card_name?(options, name) do
    case tenant_rel(options) do
      nil -> false
      %{name: rel_name} -> name == rel_name
    end
  end

  defp argument?(%Ash.Resource.Actions.Argument{}), do: true
  defp argument?(_), do: false

  # Relationship structs don't carry a `:default` key; `Map.get/2` handles
  # that without a `KeyError`. A literal `nil` means "no default declared"
  # in Ash, so anything else counts as a supplied default.
  defp has_default?(field), do: not is_nil(Map.get(field, :default))

  @doc """
  The companion file a field needs, from its handler's
  `companion_requirement/1` (`%{accept:, max_bytes:}`), or `nil` if the
  handler declines (or no handler claims the field).
  """
  def companion_requirement_for(%Field{} = field) do
    case Sheet.handler_for(field) do
      nil -> nil
      handler -> handler.companion_requirement(field)
    end
  end

  @doc """
  Stable atom used as the `allow_upload/3` name and the assigns key for a
  field's companion file input.

  Safe to construct at runtime: `name` is an Ash attribute/argument atom
  (already in the BEAM atom table from compile time), never user input.
  """
  # sobelow_skip ["DOS.BinToAtom"]
  def companion_upload_name(%Field{field: %{name: name}}) do
    :"companion__#{name}"
  end

  defp can?({resource, action}, scope) do
    Ash.can?({resource, action}, scope,
      context: %{action_source: AshBulkDurable.action_source()},
      log_policy_breakdown?: false
    )
  rescue
    _ -> false
  end
end
