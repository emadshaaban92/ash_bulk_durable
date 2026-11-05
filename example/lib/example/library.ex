defmodule Example.Library do
  @moduledoc false
  use Ash.Domain

  resources do
    resource Example.Library.Author
    resource Example.Library.Book
  end
end
