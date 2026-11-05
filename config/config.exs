import Config

# Only this repository's own tests read this: an app depending on the library
# configures it in its own config.
if config_env() == :test, do: import_config("test.exs")
