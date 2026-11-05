defmodule ExampleWeb.LibraryLive do
  @moduledoc "What bulk actions wrote: the books, newest first."
  use ExampleWeb, :live_view

  alias Example.Library.Book

  @impl true
  def mount(_params, _session, socket) do
    books =
      Book
      |> Ash.Query.sort(id: :desc)
      |> Ash.Query.limit(50)
      |> Ash.Query.load(:author)
      |> Ash.read!(authorize?: false)

    {:ok, assign(socket, :books, books)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Books
      <:subtitle>Run a bulk action to add, change or remove them.</:subtitle>
    </.header>
    <.table id="books" rows={@books}>
      <:col :let={book} label="ISBN">{book.isbn}</:col>
      <:col :let={book} label="Title">{book.title}</:col>
      <:col :let={book} label="Pages">{book.pages}</:col>
      <:col :let={book} label="Author">{book.author.name}</:col>
      <:col :let={book} label="Cover">{book.cover}</:col>
    </.table>
    """
  end
end
