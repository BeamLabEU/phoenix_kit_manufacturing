# PR #7 Review — Raise the core floor to 1.7.231, the release that ships UrlState

- **PR:** [#7](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/7)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (`8b73bd3`; branch commit `25fc132`)
- **Reviewer:** Claude (Opus 5)
- **Date:** 2026-08-06
- **Skill applied first:** `elixir:phoenix-thinking` (the claim is about a
  LiveView compile-time dependency — `use`/`on_mount` baked into the `.beam`)

## Scope

One line of `mix.exs`: `pk_dep(:phoenix_kit, "~> 1.7.190")` →
`"~> 1.7.231"`. No lock change, no `@version` change, no CHANGELOG entry (the
PR states both are maintainer-owned in this workspace — this release supplies
them).

## Verdict on the PR itself

**Correct, and correct to the exact release.** Verified against core rather
than taken from the description:

- `PhoenixKitWeb.Live.UrlState` was added to core in `ae9164c6` ("Add
  UrlState: URL-backed search, filter and page state for list LiveViews").
  `mix.exs` at that commit reads `@version "1.7.229"`, and the next version
  bump touching `mix.exs` is `140b1593` → `1.7.231`. Core's CHANGELOG
  documents `PhoenixKitWeb.Live.UrlState` under `## 1.7.231`. So 1.7.231 is
  the first *published* release containing it — `~> 1.7.230` would have been
  off by one, exactly as the PR argues. (The description says `mix.exs` read
  1.7.230 at merge; it read 1.7.229. The conclusion is unaffected.)
- The dependency is real and compile-time: `Web.MachinesLive:71` does
  `use PhoenixKitWeb.Live.UrlState`, and it is the only file that does.
- The premise that the requirement is the whole contract holds: `mix.lock` is
  not in the package's `files` list, so a consumer resolves from the
  requirement alone.
- `~> 1.7.231` is the right operator — `>= 1.7.231 and < 1.8.0` — and core is
  at 1.7.232, whose additions (impersonation entry points, i18n repairs) this
  module doesn't touch, so nothing needs a higher floor.

## Findings

### BUG - HIGH — the same stale-floor defect sat one line below, unfixed

`pk_dep(:phoenix_kit_comments, "~> 0.2")` permits 0.2.0, and this module uses
`phoenix_kit_comments` APIs that arrived well after that:

| API used here | First published in |
|---|---|
| `use PhoenixKitComments.Embed` — `Web.MachineFormLive:137` | **0.2.6** (`e11a9b0`, added at `@version "0.2.5"`) |
| `PhoenixKitComments.subscribe/2` / `unsubscribe/2` — `Manufacturing.Comments:67,77` | **0.2.8** (`65e08aa`, core CHANGELOG `## 0.2.8`, #20) |
| list form of `count_comments/3` — `Manufacturing.Comments:54` | **0.2.8** (same release, #19) |
| `composer_position` / `show_title` attrs on `CommentsComponent` | 0.2.5 (`f08bc79`) |

`phoenix_kit_comments` is a required dep, and `use PhoenixKitComments.Embed`
is unconditional, so a consumer resolving 0.2.5 or below fails to compile this
package outright; 0.2.6–0.2.7 compiles and then raises
`UndefinedFunctionError` the first time a machine list renders comment count
badges or a form subscribes. The `Code.ensure_loaded?(PhoenixKitComments)`
guards in `Manufacturing.Comments` do not cover this — they answer "is the
module there", not "is it new enough", and they return `true` for an old
`PhoenixKitComments` whose `subscribe/2` doesn't exist.

This is invisible in this workspace for the same reason the core floor was:
the lock carries 0.2.15.

**Fixed** — floor raised to `~> 0.2.8`, the highest of the four requirements
above. `mix deps.get` resolves with no lock change.

### IMPROVEMENT - MEDIUM — the comment block left a superseded floor stated as fact

`25fc132` appended its rationale below the existing V144/1.7.190 paragraph,
leaving four lines that read as the current rule ("the tables need 1.7.190")
directly above a line declaring 1.7.231. **Fixed** — the block is now one
statement of the rule for all four `pk_dep` floors, with the V144 fact kept as
the superseded floor it is, and the `phoenix_kit_comments` reasoning recorded
next to its own line.

### Verified, no change — the other two sibling floors are accurate

- `phoenix_kit_entities "~> 0.2.7"`: all ten APIs this module calls
  (`Entities.create_entity/get_entity_by_name/set_entity_translation`,
  `EntityData.get/update/list_by_entity/get_title_translation`,
  `Events.subscribe_to_entities/entity_data/all_data`) are present at tag
  `v0.2.7`; most date to 0.1.0.
- `phoenix_kit_locations "~> 0.3"`: `Spaces.full_path/2` was added when that
  repo's `mix.exs` read `@version "0.2.1"`, so 0.3.0 is its first published
  release — the floor and its comment agree.

## Test added

`test/dependency_floors_test.exs` — for each sibling dep, asserts the declared
requirement **rejects** the last release without the API this module needs and
**accepts** the first release with it (1.7.230/1.7.231, 0.2.7/0.2.8,
0.2.1/0.3.0). It reads the live requirement out of `Mix.Project.config[:deps]`
and no-ops for any dep swapped to a `path:` tuple by `pk_dep/3` under
`<APP>_PATH`, so local cross-repo runs are unaffected.

The old `~> 0.2` fails this suite (`Version.match?("0.2.7", "~> 0.2")` is
`true`), which is the point: the class of drift PR #7 fixed by hand now fails
in CI instead of in a consumer's build.

## Gate

- `mix format` — applied, tree clean
- `mix compile --force --warnings-as-errors` — clean
- `mix credo --strict` — the same 6 pre-existing notes logged by the
  [PR #5](../5-permission-label-i18n/CLAUDE_REVIEW.md) and
  [PR #6](../6-url-state-search/CLAUDE_REVIEW.md) reviews (3 "nested modules
  could be aliased", 2 "nested too deep", 1 "cyclomatic complexity"), none
  introduced here. `mix precommit`'s aggregate alias halts on these regardless
  of PR, so the remaining steps were run directly.
- `mix dialyzer` — clean
- `mix deps.unlock --check-unused` — clean
- `mix hex.audit` — no retired or security-advisory packages
- `mix test` — 127 tests, 0 failures (106 excluded: `:integration`
  auto-excluded, no PostgreSQL available). Up from 123 at merge: the 4 new
  dependency-floor tests.
