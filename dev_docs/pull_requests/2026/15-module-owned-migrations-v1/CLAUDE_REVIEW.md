# PR #15 Review — Module-owned migration chain V1 (adopts core V144 machine tables)

- **PR:** [#15](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/15)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** DRAFT at time of review; two independent passes below
- **Reviewers:** Claude (two independent passes — an implementation-focused
  two-stage review, then a fresh-context final review of the whole PR)
- **Date:** 2026-09-16

## Scope

Adds `PhoenixKitManufacturing.Migrations`, a module-owned versioned
migration coordinator (`migration_module/0`) that ADOPTS the 3 tables core's
`V144` already creates (`phoenix_kit_machines`,
`phoenix_kit_machine_type_assignments`, `phoenix_kit_machine_operations`) —
a pure Phase-0 adoption per the `phoenix_kit_hello_world` protocol. V1
changes nothing except stamping a `pkm_schema:1` marker on the anchor table.
Also adds `Machine.column_widths/0` as the single width authority for both
the chain's DDL and `Machine.changeset/2`'s own length validations, and 3
new test files (`migrations_test.exs`, `migrations_runtime_test.exs`,
`migrations_data_safety_test.exs`).

## Pass 1 — implementation-focused two-stage review

**Spec compliance: PASS.** **Code quality: Ship.** 0 critical/major/minor/nitpick.

Independently cross-checked `up_statements/2`'s actual output against core's
`v144.ex` source and `ExpectedSchema` manifest, confirmed the "no FK on
`machine_type_uuid`/`operation_uuid`" invariant against core's
`drop_fk_constraint/4` calls, confirmed `down/1` never drops a table or row
(both statically and via `migrations_data_safety_test.exs`'s real
`DestructiveRollback` mutation-check), confirmed `column_widths/0` is the
only width source, confirmed no version/floor bumps and no AI attribution.
Ran `mix format`/`credo --strict`/`dialyzer`/full `mix test` independently:
**349 tests, 0 failures**, no exclusions.

## Pass 2 — fresh-context final review (whole PR, independent of Pass 1)

**Spec: PASS** (all 8 hard requirements independently re-verified against
the real diff, a live `phoenix_kit_dev` database, and core's manifest — not
taken on Pass 1's word). **Quality/safety: 0 critical/major/minor.**

**Verdict: READY** to remove draft status as-is — "nothing must change
first."

### Nitpicks raised (all addressed in this PR before merge)

1. **Wording overclaim** — the moduledoc and `CHANGELOG.md` said core's
   source/manifest/live-DB "agree byte-for-byte." True of the *shape*
   (type/default/nullability, via the manifest's authoritative `revisions`
   field), but the manifest's `create:` ADD-COLUMN text — a repair-path
   fragment — omits `NOT NULL` on a handful of columns that are in fact
   non-null. A future reader diffing `create:` text literally would hit
   phantom deltas. **Fixed**: both places now say the three sources "agree
   on all 3 tables' shape" and the moduledoc explains the `revisions` vs.
   `create:` distinction explicitly.
2. **`up/1` does slightly more than the guarded statements** —
   `ensure_extension!/1` and `ensure_uuid_v7_function/1` run outside
   `up_statements/2`, so they sit outside the static "every statement is
   guarded" test. Net effect nil (byte-identical function body, ACL
   preserved, deliberate for Phase 2), already documented in the moduledoc,
   byte-identical to the sanctioned sibling
   `PhoenixKitCustomerSupport.Migrations`. **No code change** — exercised
   for real by `migrations_data_safety_test.exs`'s `RunUpToOne` (run twice,
   idempotent).
3. **Test failure-message overstated its own reach** — the "neither
   direction executes SQL of its own" test's message implied *every*
   statement this chain runs comes from `up_statements/2`/`down_statements/2`,
   which doesn't account for #2 above. **Fixed**: message now scoped to DDL
   run via `execute/1` specifically, with a pointer to where the two setup
   helpers are actually exercised.
4. **`down_statements(_, 0)` clears any comment, including a foreign one**
   — already documented as intended (the README's "Removing this module"
   section relies on exactly this to let an operator stop tracking without
   dropping tables). **No code change.**
5. **Process note**: this file was missing at the time of Pass 2, per
   `AGENTS.md`'s "Commit & PR conventions." **Fixed** — this file.

### Out of scope (pre-existing, confirmed untouched by this PR)

- `Machine.changeset/2`'s hard-coded `max: 2000` for `description`/`notes`
  is correct as-is — both are `TEXT` columns with no DB width.
- `@column_widths.status` (20) isn't consumed by `changeset/2` (status is
  validated via `validate_inclusion/3` instead) — harmless, only the DDL
  reads it.

## Provenance (Pass 2, independently re-run)

```
mix precommit   → exit 0 (compile --warnings-as-errors, deps.unlock --check-unused,
                   hex.audit, format --check-formatted, credo --strict, dialyzer
                   all clean; dialyzer's 2 errors both matched by .dialyzer_ignore.exs)

MIX_ENV=test PGDATABASE=phoenix_kit_test PGHOST=postgres mix test
  → 349 tests, 0 failures, no "excluded" in the summary
```

Three-source shape cross-check: all 47 `ExpectedSchema` objects for the 3
tables extracted programmatically and diffed against the real
`up_statements/2` output — 11/11 index and constraint `create` strings
normalized-identical, all 33 columns agreeing on type/default/not_null via
each object's `revisions`; confirmed again directly against a live
`phoenix_kit_dev` database via `psql \d`. Attribution grep (commit message,
PR title/body, full diff) — zero hits.

## Verdict

**PASS — Ship.** Both review passes independently reached PASS/READY with
zero blocking findings; the handful of nitpicks were wording/test-message
polish, all addressed above.

---

## Post-merge review (Claude Opus 5, 2026-09-16)

Reviewed the merged diff (`7cd333f`) together with PR #14 before cutting
0.4.5. Skills applied first: `elixir:ecto-thinking`.

Checked:

- **Protocol vs. core's driver:** `PhoenixKit.Migrations.Modules` (2.26.1)
  calls `migrated_version_runtime(prefix:)` and `current_version/0`, and
  both exist with the expected arities. `migration_module/0` is a real
  `PhoenixKit.Module` callback, so the `@impl` compiles cleanly.
- **`up/1` / `down/1` re-read the version inside migration context**
  before emitting SQL. `down/1` only runs when the marker is above the
  target, so `COMMENT ON TABLE ... IS NULL` never hits a missing table.
- **Prefix safety:** every interpolated prefix (in `qualify_table`, and
  the `nspname = '...'` literals inside the `DO $$` guards) first goes
  through `Helpers.validate_prefix!/1`.
- **Index `IF NOT EXISTS`** checks unqualified index names against the
  table's own schema, so it stays idempotent for non-`public` prefixes.
- **`column_widths/0`** feeds both the DDL and `changeset/2`, so the two
  can't drift.
- **No FK on the soft references:** confirmed. Nothing in the chain can
  drop a table.

**Findings: none.** The core-version issue found in this pass came from
PR #14, not this PR (see `14-decimal-input/CLAUDE_REVIEW.md`).
