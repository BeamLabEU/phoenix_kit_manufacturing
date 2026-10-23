# PR #8 — Codex recheck

- PR: [#8](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/8)
- Author: Max Don (@mdon)
- Reviewed: 2026-10-23
- Baseline: `2f5c93f`, including Claude's review and fixes.

## Findings and fixes

**IMPROVEMENT — MEDIUM: the committed-path guard had false negatives.**
A dependency such as `{:phoenix_kit, "~> 2.0", path: "../phoenix_kit"}`
passed because the resolved requirement reader discarded its options.
Under an environment override, a commented-out Hex declaration could also
satisfy the source regex. Both contradict the guard's stated publishing contract.

The test now parses the actual `deps/0` declarations as Elixir syntax. It rejects
path, Git, GitHub and umbrella options even alongside a version string, and
comments cannot supply a declaration. It reads declared requirements independently
of environment overrides, preserving `PHOENIX_KIT_PATH` development.

The same publishing check now covers comments, entities and locations. Their
existing version-range tests remain in place. Regression fixtures exercise
versioned and unversioned path dependencies, Git dependencies, commented pins,
both Hex tuple forms and `pk_dep/3`.

## Limits

The source check intentionally understands the dependency forms this project uses.
A future rewrite of `deps/0` to dynamically construct dependencies must update
this test. The requested broad `~> 2.0` core contract is retained; API floors
outside that contract were not changed during this six-PR recheck.

## Final project checks

- `mix precommit`: passed (warnings-as-errors, lockfile check, security audit,
  formatting, strict Credo and Dialyzer).
- `mix test`: 369 tests, 0 failures; PostgreSQL integration tests ran.
- `mix gettext.extract --check-up-to-date`: passed.
- Actual Hex archive catalog inspection and named-schema PostgreSQL probe: passed.
