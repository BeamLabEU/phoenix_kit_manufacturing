# Backlog

Deferred ideas — either out of scope for the wave that raised them, or
blocked on a dependency this module doesn't control.

## Rejected review suggestions

- **Pre-filter the featured-image picker to the machine's own folder**
  (polish-wave review, suggestion #3, 2026-07). The featured-image picker
  on `MachineFormLive` is deliberately full-library (`scope_folder_id:
  nil`, see the picker's moduledoc comment) rather than folder-scoped like
  every other picker on this module — a machine's cover photo is often
  already in the library (manufacturer stock shot, a photo picked for
  another machine), so scoping to the machine's own near-empty folder
  would hide exactly the images an admin wants. The suggestion was to
  default the picker to the machine's folder while still letting the
  admin browse elsewhere. Rejected for this wave: `MediaSelectorModal`
  (core, `phoenix_kit`) only supports a hard `scope_folder_id` restriction
  or no restriction at all — there's no "default folder, still browsable"
  mode. Revisit once core adds that capability.

## Upstream PR / CHANGELOG reminders

- Mention in the upstream PR/CHANGELOG: rollback of the module after V5 is
  not possible (`down/1` unconditionally `raise`s) — the only supported
  path is restoring a pre-V5 database backup. See
  `dev_docs/ENTITIES_MIGRATION_SPEC.md` §5.7 and the "## Rollback" section
  in `migrations/machines.ex`.
