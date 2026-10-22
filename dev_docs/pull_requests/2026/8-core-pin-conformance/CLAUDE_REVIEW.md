# PR #8 Review — Add a conformance test for the :phoenix_kit requirement

- **PR:** [#8](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/8)
- **Author:** mdon (Max Don)
- **State:** MERGED (2026-08-10)
- **Reviewer:** Claude
- **Date:** 2026-10-22

## Scope

Test-only: `test/core_pin_conformance_test.exs` asserts the `:phoenix_kit`
requirement admits every core 2.x (and rejects 1.7 / 3.x) and that no `path:` dep
has been committed.

## Findings

No bugs. Verified the test against the real `mix.exs`: the pin is
`pk_dep(:phoenix_kit, "~> 2.0")`, and `pk_dep/3` returns `{app, requirement}` /
`{app, requirement, opts}` normally and `{app, [path: …, override: true]}` under
`PHOENIX_KIT_PATH`. The test's two-step lookup handles all three shapes: the
2-tuple keyword form falls through `resolved_requirement/0` (not a binary) to the
`mix.exs` regex, which cannot match `:phoenix_kit_comments,` (it requires the
comma directly after `:phoenix_kit`). The documented local-override workflow
therefore keeps the suite green, and a committed bare `path:` dep still fails it.

- **NITPICK** — only `:phoenix_kit` is guarded; the sibling deps
  (`phoenix_kit_entities`, `_comments`, `_locations`) could be re-narrowed or
  committed as `path:` without a test noticing. Same failure class, but each
  sibling has a different valid range so a shared check would need per-dep data.
  Left as is.

## Fixes

None needed.
