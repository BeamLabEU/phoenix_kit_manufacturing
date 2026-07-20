[
  # Gettext backend plural dispatch (introduced by the first `ngettext` call
  # in this module, in `Web.MachinesLive`'s "N filters active" indicator).
  # Dialyzer can't reconcile the opaque `Expo.PluralForms` type inside the
  # compiled `lngettext/7` clauses with the literal struct terms the Gettext
  # compiler generates per locale — a known false positive in this codebase
  # family, see the analogous skip in phoenix_kit's own .dialyzer_ignore.exs.
  ~r/lib\/phoenix_kit_manufacturing\/gettext\.ex:.*call_without_opaque/,

  # `permission_metadata/0` declares `gettext_backend`/`gettext_domain` so the
  # Manufacturing row in the admin permissions matrix translates (mirroring
  # `admin_tabs/0`'s `Tab.gettext_backend`, see PR #5). Core PR #651 widened
  # `PhoenixKit.Module.permission_meta()` to accept these keys, but it merged
  # (2026-07-20T08:20Z) after `phoenix_kit` 1.7.205 — the latest Hex release
  # (published 2026-07-19T20:51Z) — so the pinned type still doesn't know
  # about them. Runtime is unaffected: `ModuleRegistry.permission_labels/0`
  # pattern-matches only `%{key:, label:}`, so the extra keys are silently
  # ignored on any core version. Remove once a `phoenix_kit` release
  # including #651 is published and the lock is bumped to it.
  ~r/lib\/phoenix_kit_manufacturing\.ex:.*callback_type_mismatch/
]
