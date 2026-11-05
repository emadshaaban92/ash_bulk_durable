[
  import_deps: [:ash, :spark],
  inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter]
]
