# PR #2 — Codex recheck

- PR: [#2](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/2)
- Author: Max Don (@mdon)
- Reviewed: 2026-10-23
- Baseline: `2f5c93f`, including Claude's review and fixes.

## Result

No additional production defect found. All three current table-backed schemas use
`PhoenixKit.SchemaPrefix`. The original `MachineType` schema has been replaced by
entities-backed records; its replacement reads use the sibling package's schemas.

Reviewed schema-backed CRUD, joins, association preloads and bulk deletes in
`Machines`, plus attachment/storage query paths. These operations retain schema
metadata. Migration SQL is explicitly qualified through the migration helpers.

The core macro reads `Application.compile_env(:phoenix_kit, :prefix)`: the setting
must exist before compilation. The PR title's "runtime" wording describes runtime
queries, not support for changing the prefix after compilation.

## Validation

The full suite covers the default schema. A separate PostgreSQL probe compiles
copies of the actual three schemas with a named prefix and exercises inserts,
reads, association preloads, bulk updates and deletes. Its schema and DDL are
contained in a rolled-back transaction. The probe passed and separately confirmed
that its temporary schema no longer existed after rollback.

## Final project checks

- `mix precommit`: passed (warnings-as-errors, lockfile check, security audit,
  formatting, strict Credo and Dialyzer).
- `mix test`: 369 tests, 0 failures; PostgreSQL integration tests ran.
- `mix gettext.extract --check-up-to-date`: passed.
- Actual Hex archive catalog inspection and named-schema PostgreSQL probe: passed.
