# Changelog

All notable changes to this project will be documented in this file.

## 0.4.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

- Sibling pins raised in step, each to that package's first release requiring
  core 2.0: `phoenix_kit_comments` → `~> 0.3`, `phoenix_kit_entities` → `~> 0.3`,
  `phoenix_kit_locations` → `~> 0.4`. `phoenix_kit_comments` 0.3.0 is a
  **security release** (stored XSS in comment bodies); see its CHANGELOG.
- `test/dependency_floors_test.exs` reframed for the new contract. Its cases
  asserted each requirement still *admitted* the release that first shipped the
  API this module calls — true while every pin sat just above its marker, false
  once the pins moved far above it. The half that still catches a real mistake
  (a pin drifting back **down** past an API in use) is kept, and a new case
  asserts every sibling pin resolves a core-2.0-era release.
- `mix precommit` passes again. Three pre-existing credo findings were blocking
  it: two too-deeply-nested filter closures in `ColumnConfig` extracted into
  named helpers, and `ColumnConfig.Machines.columns/0` (cyclomatic complexity
  16 — every column definition's anonymous functions count as branches) split
  into `identity_columns/0` + `placement_columns/0` + `date_columns/0`, order
  preserved. Two nested-module references aliased; the third is inside a
  `__using__` macro where the fully-qualified name is required for hygiene, so
  that one carries a targeted `credo:disable-for-next-line` instead.

## 0.3.4 - 2026-08-06

### Fixed

- The published `phoenix_kit` requirement named a release older than this
  module itself and permitted a core without `PhoenixKitWeb.Live.UrlState`,
  which `Web.MachinesLive` `use`s. A consumer whose resolution landed below
  1.7.231 got a package that fails to compile, or — with a precompiled
  artefact, since the `on_mount` tuple is baked into the `.beam` — raises on
  the first mount of the machines list. Floor raised to `~> 1.7.231`, the
  release that first published `UrlState`
  ([PR #7](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/7)).
- The `phoenix_kit_comments` requirement had the same defect and was two
  releases further behind: `~> 0.2` permitted 0.2.0, but
  `Web.MachineFormLive` `use`s `PhoenixKitComments.Embed` (0.2.6) and
  `Manufacturing.Comments` calls `subscribe/2`, `unsubscribe/2` and the list
  form of `count_comments/3` (all 0.2.8). The `Code.ensure_loaded?` guards
  cover the module being absent, not an older one missing functions. Floor
  raised to `~> 0.2.8`.

### Internal

- Post-merge review of #7:
  `dev_docs/pull_requests/2026/7-core-version-floor/CLAUDE_REVIEW.md`.
- `test/dependency_floors_test.exs` asserts each sibling dep's requirement
  rejects the last release without the API this module uses and accepts the
  first release with it, so a floor can no longer drift below an API in use.
  No-ops for deps swapped to a local checkout via `<APP>_PATH`.

## 0.3.3 - 2026-08-05

### Added

- The machines list's search and sort now live in the query string (`?q=`,
  `?sort=`, `?dir=`) via core's `PhoenixKitWeb.Live.UrlState`, so a filtered
  list is a real URL — shareable, reload-proof, and Back returns to the
  previous query instead of leaving the page
  ([PR #6](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/6)).
  The list loads in `handle_url_state/2`, so first paint, a shared link and a
  Back press all take one code path. Per-column filter values deliberately
  stay out of the URL — compound values need a nested encoding that hasn't
  been designed yet.
- `ColumnConfig.sortable_column_ids/0`, alongside the existing
  `all_column_ids/0`.

### Fixed

- A column-modal save or a filter change could leave the machines list stale
  when the active sort column was hidden: `__view_config_changed__/1` relied
  on the resulting URL patch to reload, but a patch that resolves to the
  current state is skipped by `UrlState.reload?/3`, and nothing else
  recomputed the list. It now reloads directly when there is no URL change to
  make.
- The sort fallback for a hidden sort column picked the first *visible*
  column, which can be the non-sortable `types` — sanitized back to the
  hidden `name`, leaving the list sorted by an invisible column with the sort
  control sitting on an unrelated one. It now picks the first *sortable*
  visible column.
- The `?sort=` whitelist is derived from `ColumnConfig.Machines` at compile
  time instead of being a hand-copied second list, so adding a sortable
  column can no longer silently leave its header un-clickable.

### Changed

- Bumped the `phoenix_kit` lock pin to `1.7.231` and dropped eight lock
  entries orphaned by the upgrade (`igniter` and its transitive deps).
- Removed the `.dialyzer_ignore.exs` entry for `permission_metadata/0`'s
  `callback_type_mismatch`: `phoenix_kit` 1.7.231 ships core PR #651, which
  widens `permission_meta()` to accept `gettext_backend`/`gettext_domain`, so
  the permission-label translation added in 0.3.2 is now live rather than
  inert.

## 0.3.2 - 2026-07-20

### Changed

- `permission_metadata/0` now declares `gettext_backend`/`gettext_domain`, so
  the "Manufacturing" row in the admin permissions matrix renders translated
  in the UI locale, matching how `admin_tabs/0` already translates the
  sidebar label ([PR #5](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/5)).
  Inert until a `phoenix_kit` release including core PR #651 is published and
  pinned — the extra keys are silently ignored by every core version
  published so far.
- Bumped the `phoenix_kit` lock pin to the latest Hex release (`1.7.205`) and
  cleaned an orphaned `beamlab_ex_aws_sqs` 4.0.0 lock entry left behind by
  core renaming its internal SQS dependency key.

### Fixed

- Declaring `permission_metadata/0`'s new keys tripped `mix dialyzer`'s
  callback-type check, since no published `phoenix_kit` version yet widens
  `permission_meta()` to include them — added a scoped, explained
  `.dialyzer_ignore.exs` entry to keep the gate green until core ships and
  the lock is bumped past it. See the [PR #5
  review](dev_docs/pull_requests/2026/5-permission-label-i18n/CLAUDE_REVIEW.md)
  for the full timeline.

## 0.3.1 - 2026-07-17

### Fixed

- 11 UI flash-message strings in `Attachments` and `Web.ColumnManagement`
  (upload/attachment errors, column-save results) were calling
  `Gettext.gettext/2` / `Gettext.dgettext/3` directly instead of through the
  macros `use Gettext, backend: ...` provides — invisible to `mix
  gettext.extract` and therefore never reaching the `et`/`ru` catalogs. Fixed
  by switching both modules to `use Gettext, backend:
  PhoenixKitManufacturing.Gettext` + the `gettext`/`dgettext` macros; the 11
  strings are now translatable and et/ru translations are included ([PR
  #4](https://github.com/BeamLabEU/phoenix_kit_manufacturing/pull/4)).
  `Attachments`'s 5 strings were also incorrectly tied to the host app's
  `PhoenixKitWeb.Gettext` backend rather than this module's own — now
  consistent with the rest of the module.

### Changed

- Routine dependency lockfile bumps (`mix.lock`).
- Removed 6 stale, unused entries from `mix.lock` (`ex_aws_sqs`, `httpoison`,
  `jose`, `metrics`, `ueberauth_apple`, `unicode_util_compat`) — orphaned
  since `phoenix_kit` dropped `ueberauth_apple` support around 1.7.191 but
  never pruned from this repo's lockfile. Includes `ueberauth_apple 0.6.1`,
  which carries a CRITICAL advisory (CVE-2026-55954, account takeover via
  missing ID token claim validation); it was not a declared dependency of
  this package and never shipped to consumers (`mix.lock` isn't published to
  Hex), but `mix hex.audit` now passes clean.

## 0.3.0 - 2026-07-14

Everything merged to `main` since 0.2.0 was published to Hex — PR #2
(`PhoenixKit.SchemaPrefix` conformance) and PR #3 ("Machines completion,
UI/i18n polish, entities-backed directories") — plus the fixes from this
release's post-merge review. 0.2.0 consumers should treat this as the first
release carrying the full "Machines reference book" feature set described
in `AGENTS.md`.

### Added

- Dynamic `metadata` fields on the machine form, driven by each linked
  machine type's `field_template` (`PhoenixKitManufacturing.Machines.merged_field_template/1`),
  with a hidden-route mini-editor (`Web.MachineTypeTemplateLive`) for editing
  a type's own template.
- Operations tab: every published `operation` (entities-backed) can be
  linked to a machine, each link optionally overriding the operation's own
  time-norm for that machine (`Machines.sync_machine_operations/3`).
- Files/attachments (`PhoenixKitManufacturing.Attachments`, `Web.Components.FilesCard`)
  and a featured-image picker on the machine form.
- Comments tab, via the optional `phoenix_kit_comments` dependency
  (`PhoenixKitManufacturing.Comments`).
- Per-user column selection/filtering/sorting for the machines list
  (`ColumnConfig`, `Web.ColumnManagement`, `Web.Components.ColumnModal`,
  `ViewConfigs`).
- `machine_type` / `operation` / `defect_reason` directories migrated off
  module-owned CRUD onto `phoenix_kit_entities`-backed blueprint entities,
  read through a new ETS+PubSub cache (`PhoenixKitManufacturing.EntitiesRegistry`)
  — see `dev_docs/ENTITIES_MIGRATION_SPEC.md`.
- Passport fields (`model`, `manufacture_year`, `commissioned_on`,
  `warranty_until`, maintenance schedule) and a soft location link
  (`location_uuid`/`space_uuid` via `phoenix_kit_locations`'s `PlacePicker`).
- `PhoenixKit.SchemaPrefix` on all table-backed schemas, for runtime
  named-schema (`--prefix`) support.

### Changed

- `MachineTypeAssignment.changeset/2`: `machine_type_uuid` is now a soft
  reference into `phoenix_kit_entities` (no `belongs_to`/FK), and the
  changeset now declares `unique_constraint([:machine_uuid,
  :machine_type_uuid])` matching core's unique index — a duplicate type
  uuid now returns `{:error, :type_assignment_failed}` instead of raising.
- `EntitiesRegistry.do_reload/1`: the ETS-payload build is now wrapped in
  the same `Postgrex.Error :undefined_table` / `catch :exit` guard already
  used for blueprint provisioning — a host booting before
  `phoenix_kit_entities`' tables are migrated no longer crashes the
  supervision tree.
- `Web.MachineFormLive`'s dynamic `metadata` fields now read from the live
  changeset instead of the frozen `@machine` struct, so a typed-but-unsaved
  value survives toggling a machine type on/off.
- `Web.MachinesLive`'s featured-image thumbnails are now batch-resolved
  (one query for the whole list) instead of one `Storage.get_file/1` call
  per row per render.
- `Web.ColumnManagement.assign_column_state/2` now falls back to
  `default_columns()` when a persisted column selection validates down to
  an empty list (e.g. every saved column id was renamed/removed), instead
  of rendering a table with no data columns.
- `Comments.available?/0` now rescues and catches `:exit`, matching this
  module's convention for every other "is this optional dependency alive"
  check.
- `phoenix_kit` pin tightened to `~> 1.7.190`; `phoenix_kit_locations`
  pinned to `~> 0.3`.

See `dev_docs/pull_requests/2026/3-machines-completion/CLAUDE_REVIEW.md` for
the full PR #3 review, including documented-but-not-fixed follow-ups
(upload content-type hardening, abandoned-draft folder cleanup, and a couple
of render-path query-batching improvements).

## 0.2.0 - 2026-07-10

### Added

- **Machines reference book** — full CRUD for manufacturing machines and
  their (many-to-many) machine types.
  - `Machine` schema: name, code, manufacturer, serial number, description,
    location note, status (`active` / `maintenance` / `decommissioned`),
    plus `data` (multilang) and freeform `metadata` JSONB columns.
  - `MachineType` schema: name, description, status (`active` / `inactive`),
    multilang `data`.
  - `MachineTypeAssignment` join schema with FK `assoc_constraint`s.
- `PhoenixKitManufacturing.Machines` context — list/get/count/create/update/
  delete for machines and types, many-to-many type sync in a transaction,
  and guarded activity logging under the `"manufacturing"` module key.
- Admin UI: `MachinesLive` (machines + types lists), `MachineFormLive`
  (core inputs + click-to-toggle type picker), and `MachineTypeFormLive`
  (multilang name/description via core `MultilangForm`).
- Module-owned database tables via `migration_module/0`
  (`PhoenixKitManufacturing.Migrations.Machines`) — the host applies them by
  running `mix phoenix_kit.update`.
- Admin nav: the Manufacturing tab now carries **Dashboard**, **Machines**
  and **Types** subtabs (plus hidden create/edit form routes).
- Dashboard now shows live machine / machine-type counts (loaded in
  `handle_params/3`, degrading to `—` when the tables have not been migrated
  yet).
- `PhoenixKitManufacturing.Errors` — centralized error-atom → message mapping.
- i18n: gettext catalog re-synced to cover all module strings — complete
  English (source) and Russian translations, plus an Estonian subset (the
  remainder falls back to English).
- Module infrastructure: `LICENSE`, `CHANGELOG.md`, `config/`, test suite,
  and `AGENTS.md`.

### Changed

- `enable_system/0` / `disable_system/0` now log the module toggle through
  the context (`Machines.log_module_toggle/1`), which records the module key
  and degrades gracefully when core's activity table is missing.
- `mix.exs`: `phoenix_kit` now resolves via the `pk_dep/3` helper (honours
  `PHOENIX_KIT_PATH` for local cross-repo work); bumped `phoenix_live_view`
  to `~> 1.1`; added `test.setup` / `test.reset` aliases and the `lazy_html`
  test dependency.

## 0.1.0 - 2026-07-09

### Added

- Initial scaffold: `PhoenixKit.Module` registration (key `manufacturing`,
  enabled via the `manufacturing_enabled` setting), admin dashboard stub, and
  centralized `Paths` helpers.
- en / et / ru translations for the dashboard.
