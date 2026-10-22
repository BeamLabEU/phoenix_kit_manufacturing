# PR #2 Review — Add PhoenixKit.SchemaPrefix for runtime named-schema support

- **PR:** [#2](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/2)
- **Author:** mdon (Max Don)
- **State:** MERGED (2026-07-13)
- **Reviewer:** Claude
- **Date:** 2026-10-22

## Scope

`use PhoenixKit.SchemaPrefix` on the table-backed schemas, a conformance test
(`test/schema_prefix_conformance_test.exs`) that fails if a `schema "phoenix_kit…"`
file lacks it, and a core floor bump to `~> 1.7.189` (since superseded by the
later floor/`~> 2.0` PRs).

## Findings

No bugs. **Reality check:** the prefix only takes effect for queries built from
schema modules, so I grepped `lib/` for string-table queries and raw SQL
(`from "phoenix_kit_…"`, `SQL.query`, `insert_all`/`update_all`/`delete_all`).
There are none — all three `delete_all`s (`Machines` ×2, `Attachments.detach_link`)
go through schema-backed `from(x in Schema)`. Today all three schemas
(`Machine`, `MachineTypeAssignment`, `MachineOperation`) carry the `use`; the
`MachineType` schema touched by this PR has since been removed (entities migration).

- **NITPICK** — the conformance test is a text match on `schema "phoenix_kit`
  and `use PhoenixKit.SchemaPrefix`. A schema whose table name doesn't start with
  `phoenix_kit`, or one using the macro through an alias, would be missed. Not
  worth a compile-time check for a module with three schemas; left as is.

## Fixes

None needed.
