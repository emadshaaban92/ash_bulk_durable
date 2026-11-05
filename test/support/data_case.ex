defmodule AshBulkDurable.DataCase do
  @moduledoc """
  A test in its own sandboxed transaction, given a super user and a region:
  every value random, so async tests never queue on a unique key.
  """
  use ExUnit.CaseTemplate

  alias AshBulkDurable.Test.{Region, Repo, User}

  using do
    quote do
      alias AshBulkDurable.Test.Repo

      import Ecto.Query, except: [update: 2, update: 3]
      import AshBulkDurable.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    super_user = create_super_user()
    %{super_user: super_user, default_region: create_default_region(super_user)}
  end

  def create_super_user do
    tag = System.unique_integer([:positive])

    Ash.create!(User, %{name: "Super User", email: "super#{tag}@example.test"},
      action: :create_super,
      authorize?: false
    )
  end

  defp create_default_region(actor) do
    tag = System.unique_integer([:positive])

    Ash.create!(
      Region,
      %{code: "D#{tag}", name: "Region #{tag}", native_name: "منطقة #{tag}"},
      actor: actor
    )
  end
end
