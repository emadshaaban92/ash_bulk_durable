defmodule ExampleWeb.CurrentUser do
  @moduledoc """
  Stands in for sign-in: the session's user, or the first seeded one. An app
  has its own; `/bulk` only needs `@scope`.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Example.Accounts.User
  alias Example.Scope

  def on_mount(:default, _params, session, socket) do
    user = user(session)
    if user, do: Gettext.put_locale(ExampleWeb.Gettext, to_string(user.locale))

    {:cont, assign(socket, :scope, Scope.new(actor: user))}
  end

  defp user(%{"user_id" => id}), do: Ash.get!(User, id, authorize?: false)

  defp user(_session) do
    User
    |> Ash.Query.sort(:email)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end
end
