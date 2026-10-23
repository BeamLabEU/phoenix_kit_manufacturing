# PR #10 — Codex recheck

- PR: [#10](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/10)
- Author: Tymofii Shapovalov (@timujinne)
- Reviewed: 2026-10-23
- Baseline: `2f5c93f`, including Claude's review.

## Findings and fixes

**BUG — MEDIUM: overridden databases lost test-partition isolation.**
With `PGDATABASE=manufacturing_test`, partitions 1 and 2 both selected the same
database. Sandbox transactions do not isolate suite bootstrap migrations or
entity provisioning. `MIX_TEST_PARTITION` now applies to both default and
overridden base names, producing `manufacturing_test1` and `manufacturing_test2`.
Without a partition, the explicit database name is retained exactly after trimming.

**BUG — LOW: whitespace-only database names became empty strings.**
The pre-trim guard accepted `PGDATABASE="   "`. Trimming now happens before the
blank check, so this uses the documented default database.

**IMPROVEMENT — LOW: the connection override omitted PGPORT.**
The `psql` bootstrap probe honors libpq's `PGPORT`, while Ecto previously used
5432. A shared server on a different port could pass discovery but fail the actual
repo connection, silently excluding integration tests. The repo config now
receives the port as an integer.

Documented the configuration contract in `AGENTS.md`. Six new tests evaluate the
real config in isolated Elixir VMs, covering defaults, blank/trimmed names,
partition suffixes, accepted and rejected pool values, and custom ports. These
tests change neither the active repo's config nor the suite's global environment.

As a regression check, ran these same six tests against an isolated copy of the
baseline config: four failed, identifying the absent explicit port, ignored
custom port, shared partition database and whitespace-only name. All six pass
against the corrected config.

## Intentional behavior

An exported `PGDATABASE` still selects that database for integration-test
bootstrap and migrations. This is the explicitly requested override mechanism;
no development/production database-name heuristic was introduced.

## Related rechecks

Independent Codex reviews also cover [#2](../2-schema-prefix/CODEX_REVIEW.md),
[#8](../8-core-pin-conformance/CODEX_REVIEW.md),
[#9](../9-priv-packaging-i18n/CODEX_REVIEW.md),
[#11](../11-dashboard-full-width/CODEX_REVIEW.md), and
[#16](../16-neutral-host-wording/CODEX_REVIEW.md).

## Final project checks

- `mix precommit`: passed (warnings-as-errors, lockfile check, security audit,
  formatting, strict Credo and Dialyzer).
- `mix test`: 369 tests, 0 failures; PostgreSQL integration tests ran.
- `mix gettext.extract --check-up-to-date`: passed.
- Actual Hex archive catalog inspection and named-schema PostgreSQL probe: passed.
