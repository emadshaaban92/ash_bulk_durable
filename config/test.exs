import Config

alias AshBulkDurable.Test

config :ash_bulk_durable,
  ecto_repos: [Test.Repo],
  ash_domains: [Test.Domain, Test.BulkActions],
  bulk_action_resource: Test.BulkAction,
  row_resource: Test.Row,
  owner_module: Test.Owner,
  storage: Test.Storage,
  pubsub_module: Test.PubSub,
  field_handlers: [Test.FilesHandler],
  phase1_concurrency: 1,
  # Tests run bulk actions with `Worker.drain/0`, not a poller.
  warn_without_poller: false

config :ash_bulk_durable, Test.Repo,
  priv: "priv/test_repo",
  username: System.get_env("DATABASE_USER", "admin"),
  password: System.get_env("DATABASE_PASSWORD", "admin"),
  hostname: System.get_env("DATABASE_HOST", "db"),
  database: "ash_bulk_durable_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 4,
  # A suite sheds no load: every process sharing a test's connection queues at
  # its owner, so wait rather than die on a checkout it would have won.
  queue_target: 5_000,
  queue_interval: 30_000,
  timeout: 60_000,
  ownership_timeout: 120_000

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: false,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  default_string_length_count: :codepoints,
  warn_on_transaction_hooks?: false

config :ash, :policies, no_filter_static_forbidden_reads?: false

config :logger, level: :warning
