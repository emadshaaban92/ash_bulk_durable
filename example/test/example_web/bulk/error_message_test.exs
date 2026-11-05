defmodule ExampleWeb.Bulk.ErrorMessageTest do
  @moduledoc """
  What no page draws here: no resolver in this app answers a reference with
  no match, so this sentence is worded directly.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Core.NoMatchError
  alias ExampleWeb.Bulk.ErrorMessage

  test "a resolver finding nothing reads on its field" do
    error = %NoMatchError{field: :photos}

    assert Exception.message(error) == "no match found"
    assert ErrorMessage.display_error(error) =~ "no match found"
  end
end
