# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :example,
  ecto_repos: [Example.Repo],
  generators: [timestamp_type: :utc_datetime]

config :example,
  ash_domains: [Example.Accounts, Example.Library, Example.BulkActions]

config :ash,
  default_page_type: :keyset,
  default_string_length_count: :codepoints

# The engine.
config :ash_bulk_durable,
  bulk_action_resource: Example.BulkActions.BulkAction,
  row_resource: Example.BulkActions.Row,
  owner_module: Example.BulkActions.Owner,
  storage: Example.BulkActions.LocalStorage,
  pubsub_module: ExampleWeb.Endpoint,
  field_handlers: [Example.BulkActions.FileHandler]

# The `/bulk` screens copied into this app.
config :example, :bulk, resources: [Example.Library.Author, Example.Library.Book]

config :example, Oban,
  engine: Oban.Engines.Basic,
  repo: Example.Repo,
  queues: [bulk_actions: 4],
  plugins: [
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", AshBulkDurable.Core.PurgeStaleStaging},
       {"*/5 * * * *", AshBulkDurable.Core.RescueStuckBulkActions}
     ]}
  ]

# Configure the endpoint
config :example, ExampleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ExampleWeb.ErrorHTML, json: ExampleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Example.PubSub,
  live_view: [signing_salt: "qCvfmNBC"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  example: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  example: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
