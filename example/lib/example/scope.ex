defmodule Example.Scope do
  @moduledoc """
  Who is acting, and in which organization. `Ash.Scope.ToOpts` lets Ash and the
  bulk verbs read it.
  """
  defstruct [:current_user, :tenant]

  def new(opts \\ []) do
    case Keyword.get(opts, :actor) do
      nil -> %__MODULE__{}
      user -> %__MODULE__{current_user: user, tenant: user.organization_id}
    end
  end

  defimpl Ash.Scope.ToOpts do
    def get_actor(%{current_user: user}), do: {:ok, user}
    def get_tenant(%{tenant: tenant}), do: {:ok, tenant}
    def get_context(_scope), do: :error
    def get_tracer(_scope), do: :error
    def get_authorize?(_scope), do: :error
  end
end
