defmodule Example.Accounts do
  @moduledoc false
  use Ash.Domain

  resources do
    resource Example.Accounts.Organization
    resource Example.Accounts.Membership
    resource Example.Accounts.User
  end
end
