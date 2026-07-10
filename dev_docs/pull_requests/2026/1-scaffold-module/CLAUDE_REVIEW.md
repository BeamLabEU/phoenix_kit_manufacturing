# PR #1 Review — Scaffold module: dashboard stub, admin menu entry, en/et/ru translations

- **PR:** [#1](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/1)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (`01cdf28`)
- **Reviewer:** Claude (Opus 4.8)
- **Date:** 2026-07-10
- **Skill applied first:** `elixir:phoenix-thinking` (PR touches a LiveView + `PhoenixKit.Module` registration)

## Scope

Initial working scaffold: `PhoenixKit.Module` registration (key `manufacturing`,
`manufacturing_enabled` setting, permission metadata, admin tab at priority 154
under Warehouse), a dashboard stub LiveView, a centralized `Paths` module, an own
Gettext backend with en/et/ru catalogs, and a Russian `DEVELOPMENT_PLAN.md`.

## Verdict

Solid, idiomatic scaffold that faithfully follows the `phoenix_kit_hello_world` /
`phoenix_kit_warehouse` conventions. Routes auto-generate from `admin_tabs/0`,
`enabled?/0` degrades safely, and the et/ru translations are correct and natural.
No blocking issues at merge time. Findings below are minor; each is already
resolved (most by the v0.2 Machines work that landed just after this PR — see the
disclosure note).

> **Disclosure.** This review runs *after* the v0.2 "Machines reference book" work
> (commit `bf0a391`), authored by the same reviewer, had already merged to `main`
> and rewritten several PR #1 files. Findings 1–2 are PR-#1-as-merged issues that
> v0.2 happened to fix; findings 4–5 are regressions v0.2 introduced and this pass
> fixes. Everything is disclosed so the record is complete.

## Findings

### BUG - MEDIUM — Module-toggle activity log was unattributed (PR #1) — FIXED
`lib/phoenix_kit_manufacturing.ex` (PR #1) logged enable/disable via a direct
`PhoenixKit.Activity.log/1` call that **omitted the `module:` field** and was not
guarded by `Code.ensure_loaded?/1`. Core's `Activity.log/1` rescues internally, so
it never crashed the toggle — but every `manufacturing_module.enabled/disabled`
activity row landed with no module attribution, so they can't be filtered by module
in the admin activity view.
**Fix:** v0.2 routes both callbacks through `Machines.log_module_toggle/1`, which
sets `module: "manufacturing"` and is guarded + rescue-wrapped.

### BUG - LOW — `package.files` referenced non-existent files (PR #1) — FIXED
`mix.exs` `package.files` listed `CHANGELOG.md` and `LICENSE`, neither of which
existed at merge. `mix hex.build` warns on missing files and the package would have
shipped with **no license file**.
**Fix:** v0.2 adds both `LICENSE` (MIT) and `CHANGELOG.md`.

### BUG - MEDIUM — DB queries in `mount/3` (v0.2 regression) — FIXED
`web/dashboard_live.ex` loaded machine/type counts in `mount/3`. `mount/3` runs
twice (static HTTP render + WebSocket connect), so the count queries ran twice per
page load — the exact anti-pattern the `phoenix-thinking` Iron Law calls out.
**Fix:** counts moved to `handle_params/3` (runs once per navigation); `mount/3`
seeds `nil` and the render degrades to `—`.

### IMPROVEMENT - MEDIUM — i18n catalog went stale (v0.2 regression) — FIXED
v0.2 added ~63 user-facing strings (machines/types lists, forms, errors) and
removed one dashboard string, but never re-extracted the catalog — so only the 4
carried-over dashboard strings stayed translated and one msgid was orphaned.
**Fix:** `mix gettext.extract` + `mix gettext.merge`; the `.pot` now holds all 68
current strings. `en` is complete (source), `ru` is fully translated, and `et`
covers the confident common-UI subset (43/68) with the remainder falling back to
English for the native-speaker maintainer to finish. The 3 bad fuzzy guesses the
merge produced (`Machine Types`→`Станки`, etc.) were corrected.

### NITPICK — `DEVELOPMENT_PLAN.md` open question on migrations — RESOLVED
The plan (§6.1) asked whether module tables should live in core's versioned
migrations (like Warehouse) or in an own `migration_module/0`. v0.2 resolved this:
**own `migration_module/0`** (`Migrations.Machines`), the `phoenix_kit_legal`
standalone-package pattern — the only viable choice for a Hex package that can't
edit core. Applied on the host via `mix phoenix_kit.update`.

## Validation

`mix format`, `mix compile --force --warnings-as-errors`, `mix credo --strict`,
and `mix dialyzer` all clean. `mix test` — 40 pass, 15 `:integration` excluded (no
PostgreSQL in the review environment; the integration suite is correct-by-
construction and runs on a host with a DB).
