# PR #6 Review — Put the machines list search and sort in the URL

- **PR:** [#6](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/6)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (`28be573`; branch commits `3be7d02`, `ed721c9`)
- **Reviewer:** Claude (Opus 5)
- **Date:** 2026-08-05
- **Skill applied first:** `elixir:phoenix-thinking` (LiveView lifecycle —
  `mount`/`handle_params`, URL-driven state, patch round-trips)

## Scope

One file, `lib/phoenix_kit_manufacturing/web/machines_live.ex`. The `:index`
list's `search` / `sort_by` / `sort_dir` move out of bare assigns and into the
query string via core's `PhoenixKitWeb.Live.UrlState`:

- `use PhoenixKitWeb.Live.UrlState` declares the three params (`?q=`, `?sort=`,
  `?dir=`), with `sort_by` whitelisted and `sort_dir` cast to an atom out of a
  closed set.
- `load_data/2` is deleted. The list now loads in `handle_url_state/2`, which
  UrlState invokes after mount and on every state change, so first paint, a
  shared link and a Back press all take one code path. The `:types` /
  `:operations` / `:defect_reasons` redirects move into `handle_params/3`, and
  `assign_column_state/2` moves into `mount/3`.
- The four sort/search event handlers push URL state instead of assigning
  (`replace: true` on the debounced search box).
- Per-column filter values deliberately stay out of the URL — compound values
  would need a nested encoding that hasn't been designed.

The follow-up commit `ed721c9` self-corrected two defects from `3be7d02`:
`handle_url_state/2` calling `assign_machines/1` bare (losing the rescue on what
is now the first-paint path), and `"types"` sitting in the sort whitelist despite
declaring `sortable?: false`.

## Verification

- **Lifecycle order confirmed against core, not assumed.** `UrlState.on_mount/4`
  attaches a `:handle_params` lifecycle hook, and attached hooks run *before* the
  LiveView's own `handle_params/3`. So the sequence is `on_mount` (params decoded
  and assigned) → `mount/3` → UrlState's hook → `handle_url_state/2` →
  `handle_params/3`. `handle_url_state/2` reading `socket.assigns[:live_action]`,
  `:locale`, `:active_filters` and `:filter_values` is therefore safe: the router
  sets `live_action` before mount, and `mount/3` sets the rest.
- **The Iron Law is not violated, and query count did not regress.**
  `assign_column_state/2` is a DB read now sitting in `mount/3`, which runs twice
  per page load — but the `load_data/2` it moved out of ran from `handle_params/3`,
  which also runs twice. On a patch (every search keystroke and sort) the new
  placement is strictly *cheaper*: the persisted view config is no longer re-read.
  Same for the delete path, which used to call `load_data(:index)` and now calls
  `assign_machines/1`.
- **Whitelist cross-checked against the real source of truth.** Enumerated
  `ColumnConfig.Machines.columns/0`: exactly ten columns declare
  `sortable?: true`, and the merged whitelist listed exactly those ten. The
  as-merged list was **correct** — but hand-copied; see IMPROVEMENT below.
- **`?dir=` is safe.** `cast: :atom` is matched against the existing atoms in
  `:in`; core never calls `String.to_atom/1` on URL input.
- **`?sort=` bounds.** No integer params are declared, so the `OFFSET` overflow
  guard core documents doesn't apply here.
- Integration tests could not be executed — no PostgreSQL in this environment, so
  `:integration` is auto-excluded per the repo's documented stance. The two new
  LiveView tests below are written but unrun locally; the gate is the bar here.

## Findings

### BUG - MEDIUM: a view-config change can leave `@machines` stale

`__view_config_changed__/1` (called by `Web.ColumnManagement` after
`set_filter_value`, `clear_filter` and a column-modal save, and by this module's
own `clear_all_filters`) took the `push_url_state` branch whenever the active
sort column was no longer visible, and relied on the resulting patch to reload
the list. That reload is not guaranteed:

```elixir
push_url_state(socket, sort_by: List.first(socket.assigns.selected_columns) || "name")
```

`push_url_state/3` → `push_patch` → UrlState's `handle_params` hook →
`apply_state/3`, which calls `handle_url_state/2` **only if `reload?/3` says the
decoded state actually moved**:

```elixir
def reload?(true, state, state), do: false
```

When the pushed `sort_by` resolves back to the value already in the assigns, the
patch goes to the same query, `reload?/3` returns `false`, `handle_url_state/2`
never runs, and this module's own `handle_params/3` doesn't touch `:machines`
either. The filter the user just typed is silently dropped.

Reachable whenever no *sortable* column is visible: select only `"types"`
(the one `sortable?: false` column), and `List.first/1` yields `"types"`, which
UrlState's `sanitize/2` rewrites to the default `"name"` — the value `sort_by`
already held. Toggling that column's filter then does nothing at all.

**Fix applied:** `__view_config_changed__/1` now resolves the next sort column
first and only patches when it differs; otherwise it reloads directly through
`reload_machines/1` (the rescue-carrying wrapper, consistent with the rest of
the module).

### BUG - MEDIUM: the sort fallback could land on a hidden or non-sortable column

The same `List.first(socket.assigns.selected_columns)` picks the first *visible*
column, not the first *sortable* visible one. `"types"` is a default column and
can be reordered to the front, so the fallback could push `"types"` — precisely
the value `ed721c9` had just removed from the whitelist. UrlState then sanitizes
it to the default `"name"`, which in this branch is itself hidden (that is why
the fallback ran). The result is the failure mode the PR set out to prevent, one
step removed: the list sorts by a column the user cannot see, `sortable_visible/1`
emits no matching `<option>`, so the sort `<select>` displays an unrelated
column, and no table header shows a sort indicator.

**Fix applied:** new `next_sort_by/1` picks the first entry of
`sortable_visible/1`, falling back to `"name"` only when nothing visible is
sortable. Locked in by a new `:integration` test asserting that hiding `"name"`
with `"types"` first in the saved order sorts by `"code"`.

### IMPROVEMENT - MEDIUM (applied): the sort whitelist was a hand-copied second registry

The `in:` list duplicated ten column ids already declared in
`ColumnConfig.Machines`. Correct as merged, but it is a second list that must
stay in sync with the first, and the drift is silent in both directions: add a
sortable column and forget this list, and clicking that column's header appears
to do nothing — `toggle_sort` pushes an id `sanitize/2` rewrites to `"name"`,
with no error anywhere and nothing pointing at a `use` block 350 lines away.

**Fix applied:** added `sortable_column_ids/0` to the `ColumnConfig` engine
(alongside the existing `all_column_ids/0`) and derived the whitelist from it at
compile time. Verified the derivation resolves to the same ten ids in the
compiled artifact, not to an empty list. Fully qualified at the call site because
the module's `alias`es are established after the `use`.

### NITPICK (applied): stale `load_data/2` references

The PR deleted `load_data/2` but left three references to it — the moduledoc's
`:types`/`:operations`/`:defect_reasons` bullet, `tab_title/1`'s comment, and
`reload_machines/1`'s comment. Repointed at `handle_params/3` and
`handle_url_state/2` respectively.

### NITPICK (not fixed): the three redirect-only routes now do a wasted view-config read

`assign_column_state/2` moved into `mount/3` unconditionally, so
`/machines/types`, `/operations` and `/defect-reasons` each perform one
`ViewConfigs.get_view_config/2` before immediately `push_navigate`-ing away.
Deliberately left alone: guarding it means branching on `live_action` in `mount/3`
for one query on three routes that never render, and the alternative placement
(inside `handle_url_state/2`) would re-read the persisted config on every search
keystroke — strictly worse. Recorded here so the trade-off is on the record.

### IMPROVEMENT - LOW (applied): gate housekeeping left by `d244b67` ("lib upgrades")

Not PR #6's doing — the unreleased `d244b67` bumped `phoenix_kit` to `1.7.231`
— but both items block the release gate, so they are cleaned here:

- `mix deps.unlock --check-unused` failed on eight entries the bump orphaned
  (`igniter` plus `ex_ast`, `glob_ex`, `owl`, `rewrite`, `sourceror`, `spitfire`,
  `text_diff`). Removed with `mix deps.unlock --unused`. Same class of drift the
  [PR #5 review](../5-permission-label-i18n/CLAUDE_REVIEW.md) cleaned for
  `beamlab_ex_aws_sqs`.
- `mix dialyzer` reported one **unnecessary skip**: `1.7.231` includes core PR
  #651, so `PhoenixKit.Module.permission_meta()` now declares
  `optional(:gettext_backend)` / `optional(:gettext_domain)` and the
  `callback_type_mismatch` ignore added in 0.3.2 is obsolete. Removed exactly as
  that review's own note instructed; verified dialyzer stays clean afterwards
  with `Unnecessary Skips: 0`. The permission-label translation shipped in 0.3.2
  is therefore live rather than inert as of this release.

## Verdict

The conversion is well-judged and the follow-up commit had already caught the
two most obvious problems on its own. What it missed is one layer down, in the
interaction between `__view_config_changed__/1`'s fallback and UrlState's
`reload?/3` short-circuit: pushing a state that resolves to the current one is a
no-op *including the reload the caller depends on*. The fallback also picked from
the wrong list — visible columns rather than sortable visible columns — which
could reproduce the very "unsorted list, sort control on the wrong column"
symptom the whitelist change was meant to eliminate. Both are fixed here; the
hand-copied whitelist is now derived so the class of drift can't recur.

## Gate

Ran against the merged state plus this review's fixes:

- `mix format` — applied, tree clean
- `mix compile --warnings-as-errors` — clean (including the new compile-time
  `sortable_column_ids/0` call, which introduces a compile-time dependency from
  `Web.MachinesLive` to `ColumnConfig.Machines`)
- `mix credo --strict` — the same 6 pre-existing notes the [PR #5
  review](../5-permission-label-i18n/CLAUDE_REVIEW.md) logged (3 "nested modules
  could be aliased", 2 "nested too deep", 1 "cyclomatic complexity"), none
  introduced here. `mix precommit`'s aggregate alias halts on these regardless of
  PR, so the remaining steps were run directly.
- `mix dialyzer` — clean
- `mix deps.unlock --check-unused` — clean
- `mix hex.audit` — no retired or security-advisory packages
- `mix test` — 123 tests, 0 failures (106 excluded: `:integration` auto-excluded,
  no PostgreSQL available). Up from 118/104 at merge: 3 new unit tests plus 2 new
  integration tests, the latter unrun in this environment.
