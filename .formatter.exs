[
  import_deps: [:ash, :ash_postgres, :spark],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter]
]
