defmodule Example.BulkActions.Owner do
  @moduledoc "A bulk action belongs to the user who submitted it, kept by id."
  @behaviour AshBulkDurable.Core.Owner

  alias Example.Accounts.User
  alias Example.Scope

  @impl true
  def worker_key(%Scope{current_user: %{id: id}}), do: id

  @impl true
  def scope_from_worker_key(user_id, tenant) when is_binary(user_id) do
    %Scope{current_user: Ash.get!(User, user_id, authorize?: false), tenant: tenant}
  end
end
