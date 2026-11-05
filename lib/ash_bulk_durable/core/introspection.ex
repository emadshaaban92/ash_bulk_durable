defmodule AshBulkDurable.Core.Introspection do
  @moduledoc """
  Rebuilds the resource and action a persisted `BulkAction` runs from the
  printable names it stores (`resource_name`, `action_name`,
  `action_type`).

  Both names are strings because either can outlive what it names: a deploy
  renames an action while a bulk action is parked, and the row must stay
  readable for its owner to abandon it.
  """

  alias AshBulkDurable.Core.StoredTerm

  @doc """
  The resource module the bulk action targets (e.g. `MyApp.Blog.Post`),
  from the module name it stored. Which resources may run in bulk is the
  caller's to decide, so any Ash resource is read back; a name naming none
  (the module renamed or gone since) raises.
  """
  def resource(%{resource_name: name}) do
    module = existing_module(name)

    if module && Ash.Resource.Info.resource?(module),
      do: module,
      else: raise(ArgumentError, "no Ash resource is named #{inspect(name)}")
  end

  defp existing_module(name) do
    Module.safe_concat([name])
  rescue
    ArgumentError -> nil
  end

  @doc "What a bulk action stores to name `resource`, as `resource/1` reads it back."
  def resource_name(resource), do: inspect(resource)

  @doc "The action type (`:create` / `:update` / `:destroy`)."
  def action_type(%{action_type: type}), do: normalize_atom(type)

  @doc "The bulk action's Ash action struct; a name naming none raises, as `resource/1`."
  def action(%{action_name: name} = bulk_action) do
    resource = resource(bulk_action)

    Enum.find(Ash.Resource.Info.actions(resource), &(to_string(&1.name) == name)) ||
      raise ArgumentError, "#{inspect(resource)} has no action named #{inspect(name)}"
  end

  @doc """
  `:ok`, or `{:error, :gone}` when the resource or action no longer exists, or
  the bulk action stored what no longer decodes.
  """
  def runnable(bulk_action) do
    action(bulk_action)
    readable([bulk_action])
  rescue
    ArgumentError -> {:error, :gone}
  end

  @doc "`:ok`, or `{:error, :gone}` when one of `records` no longer decodes."
  def readable(records) do
    if Enum.any?(records, &StoredTerm.unreadable?/1), do: {:error, :gone}, else: :ok
  end

  @doc "An atom JSONB round-tripped as a string, back to the atom."
  def normalize_atom(value) when is_atom(value), do: value
  def normalize_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
