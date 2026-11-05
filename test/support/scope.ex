defmodule AshBulkDurable.Test.Scope do
  @moduledoc "Who a test acts as: the actor, in the organization the actor is acting for."
  defstruct [:current_user, :current_tenant]

  def new(opts \\ []) do
    case Keyword.get(opts, :actor) do
      nil -> %__MODULE__{}
      user -> %__MODULE__{current_user: user, current_tenant: user.organization_id}
    end
  end

  defimpl Ash.Scope.ToOpts do
    def get_actor(%{current_user: user}), do: {:ok, user}
    def get_tenant(%{current_tenant: tenant}), do: {:ok, tenant}
    def get_context(_scope), do: :error
    def get_tracer(_scope), do: :error
    def get_authorize?(_scope), do: :error
  end
end
