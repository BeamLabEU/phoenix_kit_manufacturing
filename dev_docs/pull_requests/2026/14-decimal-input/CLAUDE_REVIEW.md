# PR #14 Review — Core decimal input for number-kind spec fields

- **PR:** [#14](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/14)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (`fc65d97`; branch head `c47c4f9`)
- **Reviewer:** Claude (Opus 5), post-merge
- **Date:** 2026-09-16
- **Skill applied first:** `elixir:phoenix-thinking`

## Scope

Swaps `<.input type="number">` for core's `<.decimal_input>` on the
machine form's dynamic `metadata` fields whose type template kind is
`number`, so a comma and a dot both work and the browser's locale-bound
number control can't swallow a value. Adds two LiveView tests.

## Findings

### BUG - HIGH — dependency floor doesn't cover the new component (documented, not changed)

`PhoenixKitWeb.Components.Core.DecimalInput` first shipped in
**phoenix_kit 2.26.0** (core CHANGELOG, #818), but `mix.exs` pins
`~> 2.0`. `mix.lock` happens to resolve 2.26.1 (the `libs` commit
`49acd83`), so CI and local builds are green. A host resolving any 2.0–2.25
would still fail to compile this package, because the `import` names a
module that isn't there.

**Why the pin wasn't raised:** I tried `~> 2.26`, and two repo tests reject
it on purpose. `test/core_pin_conformance_test.exs` requires every core 2.x
minor to be admitted, so the pin can't lock hosts out of `mix deps.get`.
`test/dependency_floors_test.exs` holds the same contract. Changing that
policy is a maintainer decision, not a post-merge fix. So the `mix.exs`
comment now names the 2.26.0 compile-time requirement, and the 0.4.5
CHANGELOG entry calls it out for host upgrades.

### BUG - MEDIUM — comma-typed values stored verbatim (fixed)

`<.decimal_input>` is a text field; its moduledoc says the server must parse
the text with `PhoenixKit.Utils.Number.parse_decimal/2`. The PR never did,
and `coerce_metadata/2` only coerced booleans. So a user typing `2,5` got
`"2,5"` in `metadata` while another machine held `"2.5"`, and anything
that sorts, compares, or exports these spec values would treat them
differently. The PR's own test only asserted the dot case round-tripped.

**Fix:** `coerce_metadata/2` now also normalizes `number` template rows:
text that `parse_decimal/2` accepts is stored as
`Decimal.to_string(d, :normal)` (`"2,5"` → `"2.5"`, `"1 000,50"` →
`"1000.5"`). Blank or unparseable text is still stored exactly as
submitted, which keeps the PR's second test ("still stores unparseable
text as submitted") and the rule that metadata is never rejected per
field. `:normal` formatting also avoids the `1E+1` exponent form that
2.26.0's `parse_decimal/2` could return for whole numbers (fixed in core
2.26.1), so any 2.26.x works. New test: *a comma-typed
number-type value is stored in canonical dot form*.

### NITPICK — trailing fraction zeros are dropped (not changed)

`parse_decimal/2` normalizes, so `"2.50"` is stored as `"2.5"`. It's the
same number and nothing is rounded, so I left it.

## Verdict

The widget swap is right. It shipped without the server-side parse the
component expects, which is fixed in 0.4.5. The core ≥ 2.26 compile-time
requirement is documented rather than enforced by the pin, per repo policy.
