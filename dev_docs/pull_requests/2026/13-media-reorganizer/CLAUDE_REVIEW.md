# PR #13 Review — Media reorganizer source for machines

- **PR:** [#13](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/13)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (`fc48ab1`; branch head `1856b8c`)
- **Reviewer:** Claude (Opus 5)
- **Date:** 2026-09-16
- **Skill applied first:** `elixir:ecto-thinking` (batched folder/machine
  queries, jsonb pointer back-fill, row locks)

## Scope

Adds `PhoenixKitManufacturing.MediaReorganizer`, which produces a plan for
core's `PhoenixKit.Modules.Storage.Reorganizer`. It moves legacy
`machine-<uuid>` / pointer folders under the parent chosen by the host's
`:attachments_parent_folder` hook, and back-fills `data["files_folder_uuid"]`.
It also reports duplicate, relocated, orphan, `hook_nil` and `hook_error`
cases, and trashes stale empty `machine-attachment-pending-*` folders.
`PhoenixKitManufacturing.media_reorganizer/0` registers it. The PR adds 66
plan-level tests.

## Verdict on the PR itself

The PR is solid. It went through seven review rounds before merge, and the
code follows the rules in core's `Source` moduledoc (2.24.0) closely:

- no moves, trashing or back-fills unless a hook is configured
- a failing hook never falls back to root
- a `nil` hook answer never pulls a folder out of its current parent
- claims don't depend on whether a hook is set
- converging targets become a duplicate report
- query count stays the same however many records there are
- the light select reads the pointer through a jsonb `fragment`
- output order is deterministic
- `counts` include every file and link, whatever its status

I also checked that the plan maps fit core's `Action.new!/1`:

- `label` is always a string, because `Machine.name` is required.
- Every `kind` is an atom.
- `after_move` is either `nil` or a 0-arity function.
- No keys outside the known set are used.

I found no correctness bugs. The findings below are about test coverage and
code hygiene.

## Findings

### IMPROVEMENT - HIGH — Plan was never run through the real engine

All 66 tests call `MediaReorganizer.plan/2` and check the maps it returns.
None of them passes the plan through `Reorganizer.run/2`, so nothing tested:

- `Action.new!/1` normalization
- `noop?/1` filtering
- the engine's lock / verify counts / `after_move` / re-verify apply path
- whether the plan converges once applied

A change in the map shape, or a back-fill that stops matching what the next
plan expects, would still pass every test.

**Fixed.** Added a `describe "through the core engine"` block. It calls
`Reorganizer.run(nil, sources: [MediaReorganizer], apply?: ...)` and covers
three cases:

1. **Legacy root folder with no pointer.** The folder moves under the hook's
   parent, and the pointer is back-filled without losing other `data` keys
   (`featured_image_uuid` stays). A second plan has no manufacturing actions.
2. **Pointer folder named like an unrelated folder already under the
   target.** The engine renames it to `"Drawings (2)"`, and the next plan is
   empty. The plan doesn't repeat the move or rename it back.
3. **Stale empty pending folder.** On apply, the outcome is `:trashed`.

All three pass against core 2.24.0.

### NITPICK — Unreachable suffix check had a different regex from core's

`noop_move?/3` had a third clause that treated `"name (N)"` as matching
`name`. Its regex, `\(\d+\)`, accepted `(0)`, `(1)` and `(02)`. Core's
`Action.matches_name?/2` only accepts N ≥ 2 without a leading zero, so the two
rules disagreed. The clause could never run, though:

- A binary `name` only comes from the legacy-name path, and that folder was
  looked up by that exact name.
- A live folder with the same name under the target is itself found by the
  lookup, so the result is a duplicate report, not a move.
- A pointer-found folder that the engine suffixed carries `name: nil`, which
  an earlier clause already matches.

**Fixed.** Removed the clause and `suffixed_variant?/2`, and added a comment
explaining why an exact match covers every case. Engine test (2) locks in that
the plan converges.

### NITPICK — Comments said core has no engine yet

Both the moduledoc and the comment on `media_reorganizer/0` said "today's hex
core does not ship the engine yet". Core 2.24.0 on Hex, which is the version
in the lockfile, does ship it. What still holds is that the `phoenix_kit ~> 2.0`
pin allows older cores, where `@behaviour` / `@impl` would produce warnings.

**Fixed.** Reworded both comments to say that. This matches the wording in
`phoenix_kit_catalogue`. `@behaviour` / `@impl` are still left out: raising the
floor to 2.24.0 would be a dependency change for every host, and none of the
sibling reorganizer modules (catalogue, crm, staff, warehouse, projects,
locations) has made that change.

### Noted, not changed

- **Pending-folder scan isn't limited by parent.** `pending_folder_actions/3`
  looks for `machine-attachment-pending-*` folders anywhere. Orphan scanning,
  by contrast, is limited to root plus the parent the hook resolved. The
  prefix belongs only to this module, and catalogue scans pending folders the
  same way. The engine won't trash a folder that still has live child folders,
  and it checks counts again at apply time. Leaving it as it is keeps it
  consistent with the other modules.
- **`hook_nil` repeats on every run.** If a host's hook answers root while
  machine folders sit under a parent, each plan produces the same `:hook_nil`
  report. The contract requires this: it tells the owner the hook and the
  existing folders disagree.
- **The moduledoc is long,** about 150 lines, and cites review-round codes
  (R2, F1, U9, …). Those codes don't mean anything outside the review threads.
  I left it alone because it matches the sibling modules, and rewriting it is
  a documentation job, not a fix.

## Validation

- `mix test test/phoenix_kit_manufacturing/media_reorganizer_test.exs`: 69
  tests, 0 failures (66 existing plus 3 engine tests)
- `mix precommit`: passed (credo, dialyzer and hex.audit all clean)
- `mix test` (full suite): 312 tests, 0 failures
- Released as 0.4.4
