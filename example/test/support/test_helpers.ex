defmodule ExampleWeb.TestHelpers do
  @moduledoc """
  A test in its own sandboxed transaction, given a super user and a region:
  every value random, so async tests never queue on a unique key.
  """
  alias Example.Accounts.User
  alias Example.Test.Region

  def common_setup(tags) do
    Example.DataCase.setup_sandbox(tags)
    super_user = create_super_user()

    %{super_user: super_user, default_region: create_default_region(super_user)}
  end

  def common_setup_with_conn(tags) do
    tags |> common_setup() |> Map.put(:conn, Phoenix.ConnTest.build_conn())
  end

  def create_super_user do
    tag = System.unique_integer([:positive])

    Ash.create!(User, %{name: "Super User", email: "super#{tag}@example.test"},
      action: :create_super,
      authorize?: false
    )
  end

  def login_as(conn, %User{id: id}), do: Plug.Test.init_test_session(conn, user_id: id)

  def create_default_region(actor) do
    tag = System.unique_integer([:positive])

    Ash.create!(
      Region,
      %{code: "D#{tag}", name: "Region #{tag}", native_name: "منطقة #{tag}"},
      actor: actor
    )
  end
end
