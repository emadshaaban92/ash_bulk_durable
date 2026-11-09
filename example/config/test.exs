import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :example, Example.Repo,
  username: System.get_env("DATABASE_USER", "admin"),
  password: System.get_env("DATABASE_PASSWORD", "admin"),
  hostname: System.get_env("DATABASE_HOST", "db"),
  database: "ash_bulk_durable_example_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 4,
  # A suite sheds no load: every process sharing a test's connection queues at
  # its owner, so wait rather than die on a checkout it would have won.
  queue_target: 5_000,
  queue_interval: 30_000,
  timeout: 60_000,
  ownership_timeout: 120_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :example, ExampleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+ehHu1QNF/4022tpGmPGBatLQJMTM6HvL7d8HJzQ1hEBGk49Q7IpyN7s00Pxjpjq",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests run bulk actions with `Worker.run_now/1` and `Worker.drain/0`.
config :example, poller?: false

config :ash_bulk_durable, phase1_concurrency: 1, warn_without_poller: false

config :ash, warn_on_transaction_hooks?: false

config :phoenix_test, :endpoint, ExampleWeb.Endpoint

config :example, :bulk,
  resources: [
    Example.Library.Author,
    Example.Library.Book,
    Example.Accounts.Organization,
    Example.Accounts.User,
    Example.Test.Region,
    Example.Test.Branch,
    Example.Test.Asset,
    Example.Test.Booking
  ]

config :ash_bulk_durable, AshBulkDurable.Storage.Local,
  root: Path.join(System.tmp_dir!(), "ash_bulk_durable_example_test")
