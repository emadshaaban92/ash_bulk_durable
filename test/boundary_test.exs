defmodule AshBulkDurable.BoundaryTest do
  @moduledoc """
  `ash_bulk_durable` stands on Ash, Oban and Postgres alone: nothing under
  `lib/` names Phoenix or ash_phoenix, not even in a comment. An app plugs in
  through config (`:owner_module`, the storage driver, the field handlers),
  never by name.

  Inside it, calls go one way: the facade (`AshBulkDurable`) calls the
  layers, and `AshBulkDurable.Core` names nothing of the package outside
  itself, so a caller's concern cannot leak into the core and every caller
  can use it.

  The core runs rows as target + input and knows no spreadsheet: no line of
  it speaks of a sheet, its columns' mapping or its companion files. The
  engine once grew shaped by the spreadsheet one reasonable-looking field
  at a time; this is what stops that.
  """
  use ExUnit.Case, async: true

  @outside ~r/\b(Phoenix|AshPhoenix|ash_phoenix)\b/
  @above_core ~r/\bAshBulkDurable\b(?!\.Core\b)/
  @sheet ~r/sheet|csv|xlsx|mapping|companion|spreadsheet/i

  test "the package names no Phoenix module" do
    files = ["lib/ash_bulk_durable.ex" | Path.wildcard("lib/ash_bulk_durable/**/*.ex")]

    assert offences(files, @outside) == [],
           "ash_bulk_durable reaches past its boundary:\n" <>
             Enum.join(offences(files, @outside), "\n")
  end

  test "the core names nothing of the package outside itself" do
    files = ["lib/ash_bulk_durable/core.ex" | Path.wildcard("lib/ash_bulk_durable/core/**/*.ex")]

    assert offences(files, @above_core) == [],
           "the core reaches a layer above it:\n" <>
             Enum.join(offences(files, @above_core), "\n")
  end

  test "the core knows no spreadsheet" do
    assert offences(core_files(), @sheet) == [],
           "the core speaks of a sheet:\n" <> Enum.join(offences(core_files(), @sheet), "\n")
  end

  defp core_files,
    do: ["lib/ash_bulk_durable/core.ex" | Path.wildcard("lib/ash_bulk_durable/core/**/*.ex")]

  defp offences(files, pattern) do
    for path <- files,
        {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(pattern, line),
        do: "#{path}:#{number}: #{String.trim(line)}"
  end
end
