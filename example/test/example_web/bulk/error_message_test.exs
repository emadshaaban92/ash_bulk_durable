defmodule ExampleWeb.Bulk.ErrorMessageTest do
  @moduledoc """
  What no page draws here: no resolver in this app answers a reference with
  no match, so this sentence is worded directly, in both languages.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Core.NoMatchError
  alias ExampleWeb.Bulk.ErrorMessage

  test "a resolver finding nothing reads on its field, in the reader's language" do
    error = %NoMatchError{field: :photos}

    assert Exception.message(error) == "no match found"

    assert Gettext.with_locale("en", fn -> ErrorMessage.display_error(error) end) =~
             "no match found"

    arabic = Gettext.with_locale("ar", fn -> ErrorMessage.display_error(error) end)
    assert arabic =~ "لا توجد نتيجة"
    refute arabic =~ "no match"
  end
end
