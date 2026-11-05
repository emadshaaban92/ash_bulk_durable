defmodule AshBulkDurable.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/emadshaaban92/ash_bulk_durable"

  def project do
    [
      app: :ash_bulk_durable,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "AshBulkDurable",
      description: "Run any Ash action over many rows durably, with per-row failures to correct",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: ["ash.codegen": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp aliases do
    [test: ["ash.setup --quiet", "test"]]
  end

  defp deps do
    [
      {:ash, "~> 3.37 and >= 3.37.1"},
      {:ash_postgres, "~> 2.15"},
      {:spark, "~> 2.7"},
      {:nimble_csv, "~> 1.3"},
      {:briefly, "~> 0.5"},
      {:telemetry, "~> 1.2"},

      # The resources the tests run, whose policies need a solver.
      {:simple_sat, "~> 0.1", only: :test},

      # Tooling.
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: [
        "lib",
        "usage-rules.md",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "usage-rules.md"]
    ]
  end
end
