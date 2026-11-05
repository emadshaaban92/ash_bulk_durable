defmodule ExampleWeb.Scenarios.BulkActionSourceScenarioTest do
  @moduledoc """
  A bulk action's writes say where they came from, because resources refuse
  the engine by that: a person's `:promote_to_super` belongs to their details
  page, one super user vouching for one person, however many a sheet could
  name. `/bulk` doesn't offer it, and a script handing it to the engine has
  each row refused, by the super user who could do it by hand.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.BulkActions.Row
  alias Example.Accounts.User
  alias Example.Test.RoleTestHelpers

  @moduletag :scenario

  test "promoting to super user runs by hand, never in bulk", %{
    conn: conn,
    super_user: super_user
  } do
    organization = RoleTestHelpers.create_organization(super_user)

    [person, other] =
      Enum.map(1..2, fn _n ->
        RoleTestHelpers.create_user_with_organization_role(super_user, organization, [:admin])
      end)

    # The page has no such action to choose, and naming it in the URL gets
    # no form.
    session =
      conn
      |> login_as(super_user)
      |> visit(~p"/bulk")
      |> select_change("Resource", option: "User")
      |> assert_has("option", text: "Update")
      |> refute_has("option", text: "Promote To Super")
      |> visit(~p"/bulk?resource=user&action=promote_to_super&identity=primary_key")
      |> refute_has("#field__id")

    # A script calling the engine is refused row by row.
    {:ok, bulk_action} =
      AshBulkDurable.update_many([{person, %{}}, {other, %{}}], User, :promote_to_super,
        scope: Example.Scope.new(actor: super_user)
      )

    assert %{success: 1, failure: 0} = AshBulkDurable.Core.Worker.drain()

    session
    |> visit(~p"/bulk")
    |> assert_has("*", text: "0 of 2 rows done")
    |> assert_has("td", text: "forbidden")

    for promoted <- [person, other] do
      refute :super_user in Ash.reload!(promoted, authorize?: false).platform_roles
    end

    # The refusal is kept without the record it refused, whose details are
    # no business of a bulk action's rows.
    rows =
      Row
      |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
      |> Ash.Query.sort(row_index: :asc)
      |> Ash.read!(authorize?: false)

    for {row, refused} <- Enum.zip(rows, [person, other]) do
      assert [%{error: %Ash.Error.Forbidden.Policy{subject: nil}} = stored] = row.error
      refute :erlang.term_to_binary(stored) =~ to_string(refused.email)
    end
  end
end
