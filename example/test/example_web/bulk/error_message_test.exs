defmodule ExampleWeb.Bulk.ErrorMessageTest do
  @moduledoc """
  What no page draws here: no resolver in this app answers a reference with
  no match, or throws or exits, and no identity a sheet looks up by matches
  two records, so these sentences are worded directly.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Core.{ManyMatchesError, NoMatchError, RowExitError}
  alias ExampleWeb.Bulk.ErrorMessage

  test "a resolver finding nothing reads on its field" do
    error = %NoMatchError{field: :photos}

    assert Exception.message(error) == "no match found"
    assert ErrorMessage.display_error(error) =~ "no match found"
  end

  test "a resolver finding more than one match reads on its field" do
    error = %ManyMatchesError{field: :photos}

    assert ErrorMessage.display_error(error) == "Photos: more than one match found"
  end

  test "a lookup matching more than one record reads on its field" do
    error = %ManyMatchesError{
      field: :organization_id,
      resource: Example.Accounts.Organization,
      criteria: %{name: "Acme"}
    }

    assert ErrorMessage.display_error(error) ==
             "Organization: more than one result in Organization matches Name = \"Acme\""
  end

  test "a resolver that throws or exits reads as unexpected, keeping its reason off the page" do
    error =
      RowExitError.new(:exit, {%RuntimeError{message: "SELECT a.lsid FROM cf.application"}, []})

    assert ErrorMessage.display_error(error) ==
             "This row hit an unexpected error, so nothing was saved for it."
  end
end
