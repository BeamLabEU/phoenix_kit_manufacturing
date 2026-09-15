[
  # Gettext backend plural dispatch (introduced by the first `ngettext` call
  # in this module, in `Web.MachinesLive`'s "N filters active" indicator).
  # Dialyzer can't reconcile the opaque `Expo.PluralForms` type inside the
  # compiled `lngettext/7` clauses with the literal struct terms the Gettext
  # compiler generates per locale — a known false positive in this codebase
  # family, see the analogous skip in phoenix_kit's own .dialyzer_ignore.exs.
  ~r/lib\/phoenix_kit_manufacturing\/gettext\.ex:.*call_without_opaque/,

  # `MapSet.member?/2` is flagged as an opaqueness mismatch on this OTP/
  # Elixir combo whenever an empty `MapSet.new/1` and a populated one meet
  # at a branch (the empty set's internal representation infers as a
  # tuple, the populated one as a map — both are valid `MapSet.t()`, this
  # is a PLT/success-typing artifact, not a real type error). Same skip as
  # `phoenix_kit_catalogue`'s media_reorganizer.ex.
  {"lib/phoenix_kit_manufacturing/media_reorganizer.ex", :call_without_opaque}
]
