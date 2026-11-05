# Changelog

## Unreleased

- First version: durable bulk actions on Oban, kept as `BulkAction` and `Row`
  records, with per-row and all-or-nothing modes, retries, a sheet layer for
  CSV and XLSX, and an errors sheet to correct and upload again.
- `example/`: a Phoenix app with a `/bulk` page to copy, using no other library
  for its screens.
