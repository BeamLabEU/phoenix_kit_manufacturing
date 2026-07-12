# AGENTS.md

Guidance for AI agents (and humans) working in `phoenix_kit_manufacturing`.

## Project Overview

`phoenix_kit_manufacturing` is a **PhoenixKit module** — an independent Hex
package that implements the `PhoenixKit.Module` behaviour and is
auto-discovered by a host Phoenix app at startup. It has no endpoint,
router, or Ecto repo of its own; it borrows the host's via `phoenix_kit`.

Current scope (v0.2): a **Machines reference book** — machines and their
many-to-many machine types, with full CRUD, activity logging, and multilang
type labels. Production orders, warehouse integration, and dashboard widgets
are planned — see `dev_docs/DEVELOPMENT_PLAN.md`.

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
5. Tables are applied by `mix phoenix_kit.update`, which discovers this
   module's `migration_module/0` and runs it.

### File layout

```
lib/phoenix_kit_manufacturing.ex              # PhoenixKit.Module implementation + admin_tabs
lib/phoenix_kit_manufacturing/
  machines.ex                                 # Context: CRUD, type sync, activity logging
  errors.ex                                   # error atom -> gettext message
  gettext.ex                                  # module Gettext backend (en/et/ru catalogs)
  paths.ex                                    # centralized path helpers
  migrations/machines.ex                      # versioned migration_module (own tables)
  schemas/{machine,machine_type,machine_type_assignment}.ex
  web/{dashboard,machines,machine_form,machine_type_form}_live.ex
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
- **Machine type** name/description are translatable via core
  `PhoenixKitWeb.Components.MultilangForm` (stored in the `data` JSONB
  column). Machine identifiers (name/code/…) use plain core inputs.

### Database & migrations

This module ships its **own** tables through `migration_module/0`
(`PhoenixKitManufacturing.Migrations.Machines`) — the standalone-package
pattern (cf. `phoenix_kit_legal`), *not* the core-migration pattern used by
first-party modules like `phoenix_kit_locations`. To add/alter tables: bump
`@current_version`, extend `up/1` + `down/1` (idempotent, prefix-aware SQL),
and update `migrated_version_runtime/1` if the probe table changes. Hosts
apply changes with `mix phoenix_kit.update`.

Tables: `phoenix_kit_machines`, `phoenix_kit_machine_types`,
`phoenix_kit_machine_type_assignments` (join, unique on
`(machine_uuid, machine_type_uuid)`, both FKs `ON DELETE CASCADE`).

**Rollback is not supported as of V5**: `down/1` unconditionally raises.
`machine_type`/`operation`/`defect_reason` data now lives in
`phoenix_kit_entities` (a separate package this migration can't losslessly
reverse-engineer a rollback for), so calling `down/1` blocks rollback of
the *whole* module (V1 through V5, not just the V5 delta) — restoring a
pre-V5 database backup is the only supported path. See the moduledoc's
"## Rollback" section in `migrations/machines.ex` for the full rationale.

## Testing

Two-level suite (see `test/test_helper.exs`):

- **Unit** tests (schemas, changesets, `Paths`, behaviour compliance) always
  run — no DB needed.
- **Integration** tests are tagged `:integration` (via `DataCase` /
  `LiveCase`) and auto-excluded when PostgreSQL is unavailable. The helper
  applies core migrations via `PhoenixKit.Migration.ensure_current/2` and
  this module's `Migrations.Machines.up/1`, then uses `Ecto.Adapters.SQL.Sandbox`.

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
