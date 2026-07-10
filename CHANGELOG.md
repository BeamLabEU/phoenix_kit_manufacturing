# Changelog

All notable changes to this project will be documented in this file.

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
- Dashboard now shows live machine / machine-type counts (degrading to `—`
  when the tables have not been migrated yet).
- `PhoenixKitManufacturing.Errors` — centralized error-atom → message mapping.
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
