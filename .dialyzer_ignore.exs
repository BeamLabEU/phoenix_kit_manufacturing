[
  # Gettext backend plural dispatch (introduced by the first `ngettext` call
  # in this module, in `Web.MachinesLive`'s "N filters active" indicator).
  # Dialyzer can't reconcile the opaque `Expo.PluralForms` type inside the
  # compiled `lngettext/7` clauses with the literal struct terms the Gettext
  # compiler generates per locale — a known false positive in this codebase
  # family, see the analogous skip in phoenix_kit's own .dialyzer_ignore.exs.
  ~r/lib\/phoenix_kit_manufacturing\/gettext\.ex:.*call_without_opaque/,

  # `Migrations.Machines.down/1` unconditionally raises as of V5 — rollback
  # is intentionally unsupported (see the moduledoc's "## Rollback"
  # section). Dialyzer correctly infers the function has no local return;
  # that is the documented, intended behavior, not a bug.
  ~r/lib\/phoenix_kit_manufacturing\/migrations\/machines\.ex:.*no_return/
]
