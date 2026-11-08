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

  test "a target looked up by one key matching more than one record reads on that key" do
    error = %ManyMatchesError{resource: Example.Accounts.Organization, criteria: %{code: "ACME"}}

    assert ErrorMessage.display_error(error) ==
             "Code: more than one result in Organization matches Code = \"ACME\""
  end

  test "a target looked up by several keys matching more than one record reads on each" do
    error = %ManyMatchesError{
      resource: Example.Accounts.Organization,
      criteria: %{code: "ACME", name: "Acme"}
    }

    assert ErrorMessage.display_error(error) ==
             "Code, Name: more than one result in Organization matches Code = \"ACME\", Name = \"Acme\""
  end

  test "a target narrowed through a relationship names the clause, reading on its own keys" do
    error = %ManyMatchesError{
      resource: Example.Accounts.Membership,
      criteria: %{name: "Acme", organization: %{code: "ACME"}}
    }

    assert ErrorMessage.display_error(error) ==
             "Name: more than one result in Membership matches " <>
               "Name = \"Acme\", Organization Code = \"ACME\""
  end

  test "a target matching nothing reads on its keys, naming the clause it was narrowed by" do
    error = %NoMatchError{
      resource: Example.Accounts.Membership,
      criteria: %{name: "Acme", organization: %{code: "ACME"}}
    }

    assert ErrorMessage.display_error(error) ==
             "Name: no result in Membership matches " <>
               "Name = \"Acme\", Organization Code = \"ACME\""
  end

  test "a target the row named no lookup for names its resource" do
    error = %NoMatchError{resource: Example.Accounts.Organization}

    assert ErrorMessage.display_error(error) == "the row names no Organization"
  end

  test "a clause two relationships deep is labelled through both" do
    error = %ManyMatchesError{
      resource: Example.Accounts.Membership,
      criteria: %{organization: %{code: "ACME"}, user: %{organization: %{code: "HQ"}}}
    }

    assert ErrorMessage.display_error(error) ==
             "more than one result in Membership matches " <>
               "Organization Code = \"ACME\", User Organization Code = \"HQ\""
  end
end
