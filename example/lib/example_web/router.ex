defmodule ExampleWeb.Router do
  use ExampleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", ExampleWeb do
    pipe_through :browser

    live_session :default,
      on_mount: ExampleWeb.CurrentUser,
      layout: {ExampleWeb.Layouts, :live} do
      live "/", LibraryLive
      live "/bulk", BulkLive.Index
    end
  end

  # Signed URLs: the token is the authorization, so no session or CSRF token.
  scope "/storage", ExampleWeb do
    put "/:token", StorageController, :put
    get "/:token", StorageController, :get
  end
end
