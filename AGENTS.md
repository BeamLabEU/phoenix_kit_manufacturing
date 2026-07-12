# AGENTS.md

Guidance for AI agents (and humans) working in `phoenix_kit_manufacturing`.

## Project Overview

`phoenix_kit_manufacturing` is a **PhoenixKit module** — an independent Hex
package that implements the `PhoenixKit.Module` behaviour and is
auto-discovered by a host Phoenix app at startup. It has no endpoint,
router, or Ecto repo of its own; it borrows the host's via `phoenix_kit`.

Current scope (v0.2): a **Machines reference book** — machines with full
CRUD, activity logging, and many-to-many links to machine types and
operations. Machine types, operations, and defect reasons are
`phoenix_kit_entities`-backed directories (migration V5), not module-owned
CRUD — see `PhoenixKitManufacturing.EntitiesRegistry` and
`dev_docs/ENTITIES_MIGRATION_SPEC.md`. Production orders, warehouse
integration, and dashboard widgets are planned — see
`dev_docs/DEVELOPMENT_PLAN.md`.

## Common Commands

```bash
mix deps.get                # Install dependencies
mix compile                 # Compile
mix test                    # Run tests (integration auto-excluded without a DB)
mix test.setup              # createdb for the test repo (needs PostgreSQL)
mix format                  # Format code (imports Phoenix LiveView rules)
mix credo --strict          # Lint / code quality
mix dialyzer                # Static type checking
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
mix precommit               # compile (warnings-as-errors) + deps.unlock check + hex.audit + quality.ci
```

## Local cross-repo development

`phoenix_kit` resolves from Hex by default. To build/test against a **local
checkout** of core (e.g. an unpublished change), export `PHOENIX_KIT_PATH`
and Mix swaps the Hex pin for a `path:` + `override: true` dep at resolve
time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Unset ⇒ the published pin, so `mix hex.publish` and CI resolve exactly as
before. Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a
`phoenix_kit` dep into a `path:` tuple; set the env var instead.

## Architecture

### How it works

1. The host app adds this package as a dependency.
2. PhoenixKit scans `.beam` files at startup and auto-discovers the module
   (zero config) via the persisted `@phoenix_kit_module` attribute set by
   `use PhoenixKit.Module`.
3. `admin_tabs/0` registers the admin pages; PhoenixKit generates routes at
   compile time from each tab's `live_view:` field.
4. Enable state is the `manufacturing_enabled` boolean setting
   (`PhoenixKit.Settings`); permissions come from `permission_metadata/0`.
5. Tables are created by PhoenixKit core (V143); this module ships no
   migrations of its own.

### File layout

```
lib/phoenix_kit_manufacturing.ex              # PhoenixKit.Module implementation + admin_tabs
lib/phoenix_kit_manufacturing/
  machines.ex                                 # Context: CRUD, type sync, activity logging
  entities_registry.ex                        # ETS+PubSub cache over phoenix_kit_entities
  errors.ex                                   # error atom -> gettext message
  gettext.ex                                  # module Gettext backend (en/et/ru catalogs)
  paths.ex                                    # centralized path helpers
  schemas/{machine,machine_type_assignment,machine_operation}.ex
  web/{dashboard,machines,machine_form,machine_type_template}_live.ex
```

### Key conventions

- **Module key** is `"manufacturing"` — consistent across `module_key/0`,
  `permission_metadata/0`, activity-log `module:`, and the settings key.
- **UUIDv7 primary keys**: `@primary_key {:uuid, UUIDv7, autogenerate: true}`.
- **Repo access** is `PhoenixKit.RepoHelper.repo()` (wrapped in `defp repo`);
  never hardcode a repo.
- **Paths**: always via `PhoenixKitManufacturing.Paths` (which routes through
  `PhoenixKit.Utils.Routes.path/1`) — never hardcode `/admin/manufacturing`.
- **URL paths** use hyphens/slashes, never underscores; tab IDs are atoms.
- **`enabled?/0`** rescues *and* `catch :exit`s, returning `false` — the DB
  may be unavailable.
- **Activity logging** is fire-and-forget: guarded by
  `Code.ensure_loaded?(PhoenixKit.Activity)`, rescues `Postgrex.Error`
  (`:undefined_table`) so a host that hasn't run core's activity migration
  never crashes. Changeset-error metadata records field *names* only (no PII).
- **LiveViews** wrap context reads in `rescue` and carry a defensive
  `handle_info/2` catch-all logging at `:debug`, so a not-yet-migrated host
  degrades instead of 500-ing.
- **Machine** identifiers (name/code/…) use plain core inputs; `Machine` is
  the only reference-book schema still module-owned.
- **`machine_type`/`operation`/`defect_reason`** live in
  `phoenix_kit_entities` (migration V5, see
  `dev_docs/ENTITIES_MIGRATION_SPEC.md`) — not module-owned CRUD. Reads and
  form pickers go through `PhoenixKitManufacturing.EntitiesRegistry` (ETS
  cache, invalidated via `PhoenixKitEntities.Events` PubSub); editing is the
  generic entities admin UI (`/admin/entities/:slug/data`, e.g.
  `/admin/entities/machine_type/data`), not a module-owned form. One
  exception: `machine_type`'s `field_template` (rendered as dynamic
  `metadata` inputs on the machine form) lives in
  `metadata["field_template"]`, a column the generic entities form never
  edits — `Web.MachineTypeTemplateLive` is a small hidden-route
  (`visible: false`) mini-editor just for that field, reachable from a
  pencil icon next to each type badge on the machine form.

### Database & migrations

This module ships **no production migrations** — all runtime database
tables (`phoenix_kit_machines`, `phoenix_kit_machine_type_assignments`,
`phoenix_kit_machine_operations`) are created by the parent
[phoenix_kit](https://github.com/BeamLabEU/phoenix_kit) project, migration
`V143`. This module only defines Ecto schemas that map to those tables.
For the full column/index list and the upgrade-path note for hosts running
the previously-published `0.2.0` (module-owned schema V1), see that
migration's moduledoc (`lib/phoenix_kit/migrations/postgres/v143.ex` in
core); for hosts with real rows still sitting in the pre-V143
`phoenix_kit_machine_types`/`phoenix_kit_operations`/
`phoenix_kit_defect_reasons` directory tables, see
`dev_docs/LEGACY_DATA_MIGRATION.md` in this repo.

The `machine_type`/`operation`/`defect_reason` directories the module reads
through `EntitiesRegistry` are **not** migration DDL either: the three
blueprint entities backing them are provisioned by
`PhoenixKitManufacturing.EntitiesRegistry.init/1` at boot — an idempotent
get-or-create against `phoenix_kit_entities`, retried at the top of every
reload until all three are confirmed present (see that module's own
moduledoc for the mechanics).

The test suite builds its schema by running core's versioned migrations
directly via `PhoenixKit.Migration.ensure_current/2` in
`test/test_helper.exs` — no module-owned DDL. **Until phoenix_kit core
publishes a Hex release containing V143**, that means integration tests
need a local core checkout with V143 on it, not just the Hex pin:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

(see "Local cross-repo development" above; point it at a checkout of
core's `core-v143-module-tables` branch, or its merged successor).

## Testing

Two-level suite (see `test/test_helper.exs`):

- **Unit** tests (schemas, changesets, `Paths`, behaviour compliance) always
  run — no DB needed.
- **Integration** tests are tagged `:integration` (via `DataCase` /
  `LiveCase`) and auto-excluded when PostgreSQL is unavailable. The helper
  applies core migrations via `PhoenixKit.Migration.ensure_current/2` (the
  module ships no migrations of its own — see "Database & migrations"
  above), then uses `Ecto.Adapters.SQL.Sandbox`.

Version-compliance: `test/phoenix_kit_manufacturing_test.exs` asserts
`version/0` equals the current release. Keep it in sync (see below).

## Versioning & Releases

Bump the version in **three places**:

1. `mix.exs` — `@version`
2. `lib/phoenix_kit_manufacturing.ex` — `version/0` (reads `@version` from
   `mix.exs`, so this is automatic)
3. `test/phoenix_kit_manufacturing_test.exs` — the `version/0` assertion

Tags are **bare version numbers** (no `v` prefix): `git tag 0.2.0 && git push
origin 0.2.0`. Add a `CHANGELOG.md` entry (`## X.Y.Z - YYYY-MM-DD`, newest
first) and run `mix precommit` clean before tagging. Publish to Hex *before*
tagging.

## Commit & PR conventions

- Commit messages start with an action verb: `Add`, `Update`, `Fix`,
  `Remove`, `Merge`.
- PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`
  using `{AGENT}_REVIEW.md` naming.
