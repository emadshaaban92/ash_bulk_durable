# Changelog

## Unreleased

- First version: durable bulk actions on Oban, kept as `BulkAction` and `Row`
  records, with per-row and all-or-nothing modes, retries, a sheet layer for
  CSV and XLSX, and an errors sheet to correct and upload again.
- `example/`: a Phoenix app with a `/bulk` page to copy, using no other library
  for its screens: organizations and roles a worker acts under, files in a
  sheet, and the page in English and Arabic.
- The engine's tests at the root, the screens' tests in `example/`, and CI over
  both.
