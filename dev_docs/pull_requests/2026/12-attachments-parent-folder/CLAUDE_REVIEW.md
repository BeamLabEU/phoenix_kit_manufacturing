# PR #12 Review — Attachment folders under a host-configured parent

- **PR:** [#12](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/12)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (`ad4e6e4`; branch commit `dcf106b`)
- **Reviewer:** Claude (Opus 5)
- **Date:** 2026-09-14
- **Skill applied first:** `elixir:ecto-thinking` (folder queries, a core
  context's update semantics)

## Scope

`Attachments` gains an optional hook,
`config :phoenix_kit_manufacturing, :attachments_parent_folder, {Mod, :fun}`,
called as `Mod.fun("machine", actor_uuid)`. It returns `{:ok, parent_uuid}` or
`nil`. New machine folders (named and pending) are created under the returned
parent. `find_folder_by_name/2` checks the parent first and then the root, so
folders from before the setting are still found. The pending-folder rename
re-resolves the parent. Also included: a CHANGELOG `Unreleased` entry and a
3-test file.

## Verdict on the PR itself

The idea is sound, and nothing changes without the config: `parent_folder_uuid`
returns `nil`, and `Storage.create_folder/1` with `parent_uuid: nil` inserts at
the root just as before. Core's `Folder.changeset/2` casts `parent_uuid`, and
`{:name, :parent_uuid}` is unique per parent, so creating `machine-<uuid>`
under a container can't clash with a root folder of the same name. The
root-fallback lookup is the right way to handle folders created before the
setting. The rename path had one real bug, and the hook call had one missing
guard.

## Findings

### BUG - MEDIUM — the pending-folder rename can move the folder out of its parent

`maybe_rename_pending_folder_for/2` changed from a rename to
`update_folder(folder, %{name: …, parent_uuid: parent_folder_uuid(resource, nil)})`.
Two problems:

1. **Core treats an explicit `parent_uuid` as a move.** This includes `nil`.
   `Storage.update_folder/3`'s doc says: "omit `:parent_uuid` from `attrs` for
   rename/recolor … Pass an explicit value to move — including `nil`, which
   means move to the system's true root."
2. **The rename passes no actor.** It runs from `save_machine/3` with no socket
   and passes `nil` as `actor_uuid`. The pending folder, however, was created
   by `ensure_folder/2` with the real `current_user_uuid`. A hook whose answer
   depends on the actor (per-user or per-tenant containers, the natural reason
   to pass an actor at all) returns `nil` here. That moves the freshly
   uploaded files' folder from the user's container back to the storage root,
   which is exactly what the feature is meant to prevent.

The move was never needed. The pending folder was already created under the
correct parent at upload time.

**Fixed:** the rename is a plain `%{name: target_name}` again, with a comment
explaining why `parent_uuid` is left out. Test: *renaming a pending folder keeps
it under its parent*. It uses an actor-dependent hook that returns `nil` for a
`nil` actor, and it fails against the merged code.

### BUG - MEDIUM — a raising host hook crashed the machine form

`parent_folder_uuid/2` calls `apply(mod, fun, …)` without a guard. A host hook
that raises crashes the LiveView from `ensure_folder/2`: in `handle_progress/3`
mid-upload, or when opening the featured-image picker. Other causes include a
mistyped module or function (`UndefinedFunctionError`) or a DB error inside
the host's lookup. The module's convention (AGENTS.md) is that host or DB
problems degrade instead of crashing. Before the finding-1 fix, the same call
also ran in the `:new` save path *after* `create_machine` succeeded, so a
raise there crashed a save that had already been committed.

**Fixed:** `parent_folder_uuid/2` rescues, logs a warning and returns `nil`
(storage root). Test: *a raising hook degrades to the storage root*.

### IMPROVEMENT - LOW — the hook received the opaque scope key, not the resource type

`ensure_folder/2` called `parent_folder_uuid(scope, …)` with the per-page scope
key. The module doc describes scope keys as opaque, "typically the resource's
id or a draft id". Today the only key is the literal `"machine"`, so the two
match. A future page keyed by resource id, though, would pass a UUID to a hook
documented to receive `"machine"`, and would silently get the root.

**Fixed:** resolve by `st.resource || scope`. The `%Machine{}` clause maps
the struct to `"machine"`, whatever the key is.

### NITPICK — CHANGELOG described the hook's arguments inaccurately

The entry said `fun.(scope_or_resource, actor_uuid)`. The hook only ever gets
the string. **Fixed** while moving the entry to `0.4.3`.

### Test gap — parent-first lookup was untested

The existing *checks parent then root* test covers only the root fallback.
Both branches returned the same folder, so a lookup that ignored the parent
entirely would still pass. **Added** *prefers the parent when both exist*:
same name at root and under the container, the container's folder must win.

### Verified, no change

- **Lookup falls back to root and never migrates.** A pre-existing
  `machine-<uuid>` folder at root is reused where it is, not moved into the
  container. Moving it silently would be surprising, and the host can
  reorganise in the media UI. This is intentional and documented.
- **A hook returning a non-existent parent UUID** makes `create_folder` fail on
  `foreign_key_constraint(:parent_uuid)`. The error already surfaces as the
  "Could not prepare the files folder" / upload-failed flash, so no crash.
- **`Application.get_env/2` at call time** (not `compile_env`) is right for a
  host-set runtime option.

## Tests verified against the merged code

With `attachments.ex` temporarily reverted to `ad4e6e4`, the file runs
6 tests, 2 failures. *renaming a pending folder keeps it under its parent*
fails with `parent_uuid` `nil` (moved to root) instead of the container.
*a raising hook degrades to the storage root* fails with the `RuntimeError`
propagating. Both pass with the fixes.

## Gate

- `mix format`: applied
- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, `format --check-formatted`, `credo --strict`, dialyzer):
  **passed**, exit 0. Credo reported no issues in 613 mods/funs. Dialyzer's
  2 errors are both covered by existing `.dialyzer_ignore.exs` skips, with
  0 unnecessary skips.
- `mix test`: 243 tests, 0 failures (PostgreSQL available, so integration
  tests ran). The logged "Failed to load machine types … ETS table" lines are
  existing `EntitiesRegistry` degrade-path logs from tests with no registry
  started, not failures.

## Release

Shipped as **0.4.3**, together with the `lib upgrades` lock bump (`d804a2f`:
`phoenix` 1.8.14, `phoenix_kit` 2.23.1, `phoenix_kit_entities` 0.4.13,
`beamlab_countries` 1.2.1).
