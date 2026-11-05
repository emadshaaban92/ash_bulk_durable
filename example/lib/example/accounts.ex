defmodule Example.Accounts do
  @moduledoc false
  use Ash.Domain

  resources do
    resource Example.Accounts.User
  end
end
