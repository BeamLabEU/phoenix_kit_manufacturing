# PR #10 Review — test: make the test database name overridable via PGDATABASE (+ PGPOOL)

- **PR:** [#10](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/10)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (2026-08-25)
- **Reviewer:** Claude
- **Date:** 2026-10-22

## Scope

`config/test.exs` reads `PGDATABASE` for the database name and `PGPOOL` for the
pool size (validated positive integer), falling back to the previous defaults.

## Findings

No bugs. Cross-checked the consumers of the name: `test_helper.exs` derives its
`psql -lqt` existence check from the repo's configured `:database`, and
`mix test.setup` runs `ecto.create -r …Test.Repo`, so both follow the override.
Unset env keeps CI and publishing unchanged.

- **NITPICK** — an explicit `PGDATABASE` ignores `MIX_TEST_PARTITION`, so
  partitioned runs against one overridden database would share state. Matches
  core's `config/test.exs` ("same mechanism"), and the override exists for shared
  instances where partitioning isn't in play. Left as is.
- **NITPICK** — `PGDATABASE` is a standard libpq variable that developers often
  export globally; with it set to a dev database, `mix test` runs core migrations
  and the `pkm_schema` stamp against that database (the sandbox only rolls back
  test data). Same trade-off as core and called out in the config comment; not
  worth diverging from core's variable name.

## Fixes

None needed.
