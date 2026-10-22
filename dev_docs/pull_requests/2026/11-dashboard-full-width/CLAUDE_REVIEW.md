# PR #11 Review — Let the manufacturing dashboard use the full content width

- **PR:** [#11](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/11)
- **Author:** timujinne (Tymofii Shapovalov)
- **State:** MERGED (2026-09-08)
- **Reviewer:** Claude
- **Date:** 2026-10-22

## Scope

One class change in `DashboardLive.render/1`: drops `mx-auto max-w-3xl`.

## Findings

No bugs. Presentation-only; no assigns, events, or queries touched (`mount` does
no DB work). Note the other pages cap at `max-w-screen-2xl mx-auto w-full`
(`MachineFormLive`, `MachineTypeTemplateLive`), so the dashboard is now the only
unbounded page.

- **NITPICK** — on ultra-wide displays the "Coming soon" stub cards stretch
  edge to edge. The dashboard is a placeholder until production-order widgets
  land; revisit the cap then. Left as is, since "full content width" is the
  stated intent.

## Fixes

None needed.
