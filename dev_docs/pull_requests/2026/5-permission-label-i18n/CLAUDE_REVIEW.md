# PR #5 Review — Declare the gettext backend for the manufacturing permission label

- **PR:** [#5](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/5)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (`139f5f0`)
- **Reviewer:** Claude (Sonnet 5)
- **Date:** 2026-07-20
- **Skill applied first:** `elixir:elixir-thinking` (general module-callback change, no LiveView/Ecto/OTP surface)

## Scope

One-line-of-intent diff (`lib/phoenix_kit_manufacturing.ex`): `permission_metadata/0`
now declares `gettext_backend: PhoenixKitManufacturing.Gettext` and
`gettext_domain: "default"`, so the "Manufacturing" row in the admin permissions
matrix renders translated — the same two fields `admin_tabs/0` already sets on
every `%Tab{}` for the sidebar label. The `Manufacturing` msgid is already
translated in this package's `et`/`ru` catalogs, so no catalog work was needed.

This depends on core PR
[phoenix_kit#651](https://github.com/BeamLabEU/phoenix_kit), which widens
`PhoenixKit.Module.permission_meta()` to accept these two optional keys and
teaches `ModuleRegistry`/`Permissions.module_label/1` to resolve them. The PR
description states the extra keys are "simply ignored" without the core change,
"so merging early is harmless."

## Verification

- Confirmed the pattern is an exact match for the 10 existing `gettext_backend:
  PhoenixKitManufacturing.Gettext, gettext_domain: "default"` pairs already on
  every `%Tab{}` in `admin_tabs/0` — not a one-off guess at core's field names.
- Confirmed the `Manufacturing` msgid has real (non-placeholder) `et`/`ru`
  translations in `priv/gettext/{et,ru}/LC_MESSAGES/default.po` (`Tootmine`,
  `Производство`), so the PR's translation-work claim holds.
- Confirmed the "harmless without core" claim **at runtime**: in every
  published `phoenix_kit` version so far, `ModuleRegistry.permission_labels/0`
  builds its map via `Map.new(fn %{key: key, label: label} -> {key, label} end)`
  — a partial match on a plain map, so the two extra keys are silently dropped
  regardless of core version. No crash risk.
- **The "harmless" claim does not hold for the gate**, though — see Findings.

## Findings

### BUG - MEDIUM: extra `permission_metadata/0` keys fail `mix dialyzer`'s callback-type check against every currently-published core version

`PhoenixKit.Module`'s `@callback permission_metadata() :: permission_meta() | nil`
is backed by a **closed** map type:

```elixir
@type permission_meta :: %{
        required(:key) => String.t(),
        required(:label) => String.t(),
        required(:icon) => String.t(),
        required(:description) => String.t(),
        optional(:sub_permissions) => [sub_permission()]
      }
```

Unlike `PhoenixKit.Dashboard.Tab` (a real struct whose `t()` already lists
`gettext_backend`/`gettext_domain`, which is why `admin_tabs/0`'s use of those
fields was always fine), `permission_meta()` had no `gettext_backend`/
`gettext_domain` keys before core PR #651. Dialyzer checks a behaviour
implementation's return type against the callback's declared spec, so
`permission_metadata/0` returning those two extra keys is a genuine
`callback_type_mismatch` — reproduced locally against the pinned core:

```
lib/phoenix_kit_manufacturing.ex:82:7:callback_type_mismatch
Type mismatch for @callback permission_metadata/0 in PhoenixKit.Module behaviour.
Expected type: nil | %{:description => binary(), :icon => binary(), :key => binary(),
  :label => binary(), :sub_permissions => [...]}
Actual type: %{:description => ..., :gettext_backend => PhoenixKitManufacturing.Gettext,
  :gettext_domain => ..., :icon => ..., :key => ..., :label => ...}
```

Traced why core PR #651 doesn't fix this yet: it merged **2026-07-20T08:20:42Z**,
but the latest `phoenix_kit` Hex release, `1.7.205`, was published
**2026-07-19T20:51:16Z** — before the merge. No published `phoenix_kit` version
contains the widened `permission_meta()` type yet, so this fails
`mix dialyzer` (and therefore `mix precommit`/`mix quality.ci`) on **any**
currently-installable core, not just the stale lock this repo happened to have.

This is a real gap in the PR's "harmless" framing: it's harmless at runtime,
but not gate-harmless — merging it as-is breaks CI/`mix precommit` until core
ships and this repo's lock is bumped past #651.

**Fix applied:** added a scoped, explained entry to `.dialyzer_ignore.exs`
(matching this repo's existing convention of a commented regex per known gap,
see the adjacent `gettext.ex` entry) covering
`lib/phoenix_kit_manufacturing.ex:.*callback_type_mismatch`, with a comment
recording the exact timing (#651 merge vs. 1.7.205 publish) and a note to
remove it once a `phoenix_kit` release including #651 is published and pinned.

### IMPROVEMENT - LOW (applied): stale `phoenix_kit` lock

Unrelated to the above (bumping the lock does *not* pull in #651 — it isn't
published yet), but `mix.lock` was pinned to `phoenix_kit` `1.7.199` while
`mix.exs`'s `~> 1.7.190` requirement already permitted the latest published
`1.7.205`. Bumped via `mix deps.update phoenix_kit`. This is the same kind of
lock drift the [PR #4 release](../4-i18n-runtime-gettext/CLAUDE_REVIEW.md)
flagged previously (that one for a CVE-flagged orphaned entry); this one carries
several months of unrelated upstream fixes and keeps the module on the latest
core. Also removed one newly-orphaned lock entry the bump left behind:
`phoenix_kit` 1.7.205 renamed its internal SQS dependency key from
`beamlab_ex_aws_sqs` to `ex_aws_sqs` (still resolving the same
`:beamlab_ex_aws_sqs` Hex package, now at `5.0.0`), which stranded the old
`"beamlab_ex_aws_sqs": {..., "4.0.0", ...}` lock line; cleaned via
`mix deps.unlock --unused`.

## Verdict

The PR's own change is correct and minimal — it's the exact established
pattern from `admin_tabs/0`, aimed at a real core capability, with translations
already in place. Its only fault is a type-spec gap it didn't anticipate:
"ignored at runtime" isn't the same as "clean under dialyzer," and no published
core version supports the new keys yet. Fixed here with a documented, removable
dialyzer-ignore entry rather than reverting the PR — the feature is inert but
correct, and will start working the moment core publishes #651 and this
repo's lock is bumped past it.

## Gate

Ran against the merged state plus this review's fixes
(`.dialyzer_ignore.exs` entry, `mix.lock` bump + unused-entry cleanup):

- `mix compile --warnings-as-errors` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — 6 pre-existing Design/Refactoring notes (3 "nested
  modules could be aliased", 2 "nested too deep", 1 "cyclomatic complexity"),
  none in `phoenix_kit_manufacturing.ex` or otherwise touched by this PR;
  matches the same pre-existing set the [PR #4
  review](../4-i18n-runtime-gettext/CLAUDE_REVIEW.md) already logged as
  out-of-scope. (`mix precommit`'s aggregate alias halts here since `credo
  --strict` exits non-zero on these notes regardless of PR — ran the
  remaining gate steps directly instead.)
- `mix dialyzer` — clean (was failing with `callback_type_mismatch` before
  the `.dialyzer_ignore.exs` fix; confirmed clean both with a stale and a
  freshly rebuilt PLT)
- `mix deps.unlock --check-unused` — clean
- `mix hex.audit` — no retired or security-advisory packages
- `mix test` (unit; DB unavailable so `:integration` auto-excluded per repo
  convention) — 118 tests, 0 failures
