# PR #9 — Codex recheck

- PR: [#9](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/9)
- Author: Tymofii Shapovalov (@timujinne)
- Reviewed: 2026-10-23
- Baseline: `2f5c93f`, including Claude's catalog fix.

## Findings and fixes

Claude's addition of "Machine Type Template" to the template and English catalog
is correct. Its manual `elixir-format` flag also correctly keeps the dynamic
message through extraction; extraction does not remove that entry.

**IMPROVEMENT — MEDIUM: the new parity guard skipped valid PO message forms.**
The regex ignored IDs split over multiple lines and did not compare contexts or
plural IDs. Matching only the singular ID could therefore pass while the runtime
translation keys differed.

The guard now uses Expo's PO parser (already supplied by Gettext), compares
normalized context, singular and plural IDs, and excludes obsolete entries.
Regression fixtures cover multiline IDs, contextual messages, plural IDs and
obsolete translations. Required locales are checked as a subset, permitting
additional locales.

A second check derives runtime tab and permission labels from the module's public
metadata and requires them in the template. This catches labels omitted from
every catalog, which parity alone cannot detect. The module behavior test now
also resolves the hidden template tab in both Estonian and Russian.

**NITPICK: extracted source references were stale.** A real
`mix gettext.extract --check-up-to-date` failed. Extraction changed only source
references; the refreshed POT preserves every message and translation.

## Package verification

Built an actual Hex archive with `mix hex.build -o /tmp/phoenix_kit_manufacturing-review.tar`
and inspected its nested `contents.tar.gz`. The en, et and ru PO files are all
present. The packaging fix is correct.

## Shared validation finding

The first `mix precommit` run detected a newly published, medium-severity advisory
for locked `plug_crypto 2.2.0`. Updated only that lock entry to patched
`2.2.1`. This is a current dependency issue, not a regression attributed to #9.
The [upstream advisory](https://github.com/elixir-plug/plug/security/advisories/GHSA-ffw9-w85g-f2vh)
identifies the affected versions and the patched release. A library's lockfile
does not constrain a consuming host's lockfile.

## Final project checks

- `mix precommit`: passed (warnings-as-errors, lockfile check, security audit,
  formatting, strict Credo and Dialyzer).
- `mix test`: 369 tests, 0 failures; PostgreSQL integration tests ran.
- `mix gettext.extract --check-up-to-date`: passed.
- Actual Hex archive catalog inspection and named-schema PostgreSQL probe: passed.
