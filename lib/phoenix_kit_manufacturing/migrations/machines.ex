defmodule PhoenixKitManufacturing.Migrations.Machines do
  @moduledoc """
  Versioned migration for the Manufacturing module.

  Creates and extends the machines reference-book tables. As of V5, three
  of them (`phoenix_kit_machine_types`, `phoenix_kit_operations`,
  `phoenix_kit_defect_reasons`) are migrated into `phoenix_kit_entities`
  and dropped — see the V5 bullet below and
  `dev_docs/ENTITIES_MIGRATION_SPEC.md` for the full rationale:

    * `phoenix_kit_machines` — machine records.
      * V1: identity + status core columns (`name`, `code`, `manufacturer`,
        `serial_number`, `description`, `location_note`, `status`, `data`,
        `metadata`).
      * V2: extended passport (`model`, `manufacture_year`,
        `commissioned_on`, `warranty_until`, `to_last_on`,
        `to_interval_days`, `to_next_on`, `notes`) and a soft link to
        `phoenix_kit_locations` (`location_uuid`, `space_uuid`, indexed via
        `idx_machines_location`). These are intentionally *not* real
        foreign keys — `phoenix_kit_locations` is a soft, optional
        cross-module reference (see `PhoenixKitManufacturing.Machines.location_label/2`).
    * `phoenix_kit_machine_types` — machine type records (dropped in V5;
      see below).
      * V1: `name`, `description`, `status`, `data`.
      * V2: `field_template` (JSONB array, default `[]`) — the per-type
        dynamic metadata field definitions rendered on the machine form.
    * `phoenix_kit_machine_type_assignments` (join, V1 only). `machine_type_uuid`
      is a real FK to `phoenix_kit_machine_types` through V4; V5 drops that
      constraint — the column becomes a soft reference to
      `phoenix_kit_entity_data.uuid`, same trade-off as `phoenix_kit_machines.location_uuid`.
    * `phoenix_kit_operations` (V3, dropped in V5; see below) — global
      operation directory: `name`, `unit`, `base_time_norm_seconds`,
      `status`, `data`.
    * `phoenix_kit_machine_operations` (join, V3) — machine<->operation
      linking with an optional per-machine `time_norm_seconds` override
      (`NULL` means "use the operation's `base_time_norm_seconds`"),
      unique on `(machine_uuid, operation_uuid)`. `operation_uuid` is a
      real FK to `phoenix_kit_operations` through V4; V5 drops that
      constraint — the column becomes a soft reference to
      `phoenix_kit_entity_data.uuid`.
    * `phoenix_kit_defect_reasons` (V4, dropped in V5; see below) — global
      defect-reason directory: `name`, `description`, `status`, `data`. A
      plain reference book, not linked (M2M or otherwise) to
      machines/operations in this wave.
    * V5 — migrates every `phoenix_kit_machine_types` / `phoenix_kit_operations`
      / `phoenix_kit_defect_reasons` row into a `phoenix_kit_entities`
      blueprint entity (`"machine_type"` / `"operation"` / `"defect_reason"`,
      provisioned idempotently) as a `phoenix_kit_entity_data` record:
      multilang `_name`/`_description` become `_title`/`_description`
      (entities' reserved title key), `unit`/`base_time_norm_seconds`
      (operation) land unprefixed in the primary-language data block,
      `field_template` (machine_type) moves to `metadata["field_template"]`
      (not `data` — the generic entities form replaces the whole
      primary-language `data` block on every save, which would silently
      drop an undeclared key living there), and the source row's uuid is
      stamped as `metadata["legacy_uuid"]` for idempotency/retry-safety.
      Then rewrites `phoenix_kit_machine_type_assignments.machine_type_uuid`
      and `phoenix_kit_machine_operations.operation_uuid` to the new
      `phoenix_kit_entity_data` uuids, drops both FK constraints, and
      drops the three source tables. `phoenix_kit_defect_reasons` has no
      other table referencing it, so only its rows move — there is no
      third rewrite step.

  All statements use `IF NOT EXISTS` guards — safe to run multiple times.
  `up/1` is cumulative: a single call (re-)applies every version's
  statements in one pass, not just the delta since the last-applied
  version.

  Implements the versioned-migration protocol expected by PhoenixKit Core
  (`mix phoenix_kit.update`): `current_version/0` and
  `migrated_version_runtime/1`. The host applies these by running
  `mix phoenix_kit.update`, which discovers this module via
  `PhoenixKitManufacturing.migration_module/0`, diffs the applied version
  against `current_version/0`, and generates + runs a wrapper migration.
  Reference implementation — `PhoenixKit.Migrations.Postgres` in Core.

  Depends on `uuid_generate_v7()`, provided by core's early migrations.

  `@disable_ddl_transaction true` is declared below for forward-compatibility
  and to document intent, but is currently inert in practice: the host
  wrapper `mix phoenix_kit.update` generates
  (`generate_module_migration/5`) does not read this attribute off an
  external `migration_module` — only core's own migrations get that
  treatment. A `mix phoenix_kit.update` run against a PgBouncer-fronted
  database is therefore *not* actually protected from a mid-batch
  transaction drop by this flag; verify column/table presence afterwards
  regardless (see `version_probes/0` below).

  ## Version detection

  `migrated_version_runtime/1` walks `version_probes/0` — a
  `[{version, probe_fun}]` list, highest version first — and returns the
  version of the first probe that passes (`0` if none do). Each probe must
  check *every* structural addition its version introduced (every new
  column on every table it touched, every new table) rather than a single
  representative — a partially-applied migration (e.g. PgBouncer silently
  dropping some `ALTER TABLE` statements while `schema_migrations` still
  records success) would otherwise be reported as fully migrated forever.
  Add a `{version, probe}` pair to `version_probes/0` every time
  `@current_version` is bumped.

  ## Rollback

  `down/1` is **not supported** as of V5 — it unconditionally raises. Once
  `machine_type`/`operation`/`defect_reason` data has moved into
  `phoenix_kit_entities` (a separate package whose tables this migration
  neither owns nor attempts to reverse-engineer a lossless inverse mapping
  for), there is no code path back. This blocks rollback of the *entire*
  module (V1 through V5), not just the V5 delta — `down/1` has always been
  a single all-or-nothing operation with no incremental per-version path
  (the pre-V5 behavior was already "drop all six tables", never "V2 -> V1
  keeping V1 data intact"), so there was no partial-rollback capability to
  preserve. Restoring a pre-V5 database from a backup is the only
  supported rollback path. Any `opts` argument is accepted for
  call-signature symmetry with `up/1` but is not consulted.
  """

  use Ecto.Migration

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData

  @disable_ddl_transaction true

  @current_version 5

  @doc "Target schema version of the Manufacturing module."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Currently applied schema version, read from the database.

  Runs `version_probes/0` from highest to lowest version and returns the
  version of the first probe that passes. Returns `0` when no probe passes
  (nothing migrated yet) or the probe query itself failed. `opts` is a
  keyword list or map with an optional `:prefix`.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    prefix = normalize_prefix(opts)

    version_probes()
    |> Enum.sort_by(fn {version, _probe} -> version end, :desc)
    |> Enum.find_value(0, fn {version, probe} -> if probe.(prefix) == true, do: version end)
  rescue
    _ -> 0
  end

  # Highest-version-first probe list, walked by `migrated_version_runtime/1`.
  # Each probe is a `(prefix -> boolean)` closure checking every structural
  # addition that version introduced. Extend this list (never rewrite past
  # entries) whenever `@current_version` is bumped.
  @spec version_probes() :: [{pos_integer(), (String.t() -> boolean())}]
  defp version_probes do
    [
      {1, &probe_v1?/1},
      {2, &probe_v2?/1},
      {3, &probe_v3?/1},
      {4, &probe_v4?/1}
    ]
  end

  # V1 created three tables — check all of them, not just one representative,
  # so a partially-applied `up/1` (e.g. cut short mid-batch) reads back as
  # "not migrated" rather than silently passing for V2+.
  defp probe_v1?(prefix) do
    table_exists?(prefix, "phoenix_kit_machines") and
      table_exists?(prefix, "phoenix_kit_machine_types") and
      table_exists?(prefix, "phoenix_kit_machine_type_assignments")
  end

  # V2 added 10 columns to phoenix_kit_machines (passport fields + the soft
  # location link) and 1 column to phoenix_kit_machine_types
  # (field_template). Check every one of them — not just a representative
  # column — so a partial apply (e.g. PgBouncer dropping some but not all
  # `ALTER TABLE` statements) can never read back as "fully migrated to V2".
  @v2_columns [
    {"phoenix_kit_machines", "model"},
    {"phoenix_kit_machines", "manufacture_year"},
    {"phoenix_kit_machines", "commissioned_on"},
    {"phoenix_kit_machines", "warranty_until"},
    {"phoenix_kit_machines", "to_last_on"},
    {"phoenix_kit_machines", "to_interval_days"},
    {"phoenix_kit_machines", "to_next_on"},
    {"phoenix_kit_machines", "notes"},
    {"phoenix_kit_machines", "location_uuid"},
    {"phoenix_kit_machines", "space_uuid"},
    {"phoenix_kit_machine_types", "field_template"}
  ]

  defp probe_v2?(prefix) do
    Enum.all?(@v2_columns, fn {table, column} -> column_exists?(prefix, table, column) end)
  end

  # V3 created two new tables (the operations directory and the
  # machine<->operation join) — check both, not just one representative,
  # so a partial apply (e.g. PgBouncer dropping the second `CREATE TABLE`
  # while the first commits) can never read back as "fully migrated to V3".
  defp probe_v3?(prefix) do
    table_exists?(prefix, "phoenix_kit_operations") and
      table_exists?(prefix, "phoenix_kit_machine_operations") and
      unique_index_exists?(
        prefix,
        "phoenix_kit_machine_operations",
        "idx_machine_operations_unique"
      )
  end

  # The unique (machine_uuid, operation_uuid) index is a structural
  # integrity element, not an optimisation: without it two concurrent
  # sync_machine_operations calls can insert duplicate links. Include it
  # in the probe so a partial PgBouncer apply that ate the CREATE UNIQUE
  # INDEX (but committed both tables) still reads back as "V3 missing".
  defp unique_index_exists?(prefix, table, index) do
    query = """
    SELECT 1 FROM pg_indexes
    WHERE schemaname = $1 AND tablename = $2 AND indexname = $3
      AND indexdef LIKE 'CREATE UNIQUE%'
    """

    case repo().query(query, [prefix || "public", table, index]) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  end

  # V4 created a single new table (the defect-reasons directory) via one
  # atomic CREATE TABLE statement — checking its presence covers every
  # structural addition this version introduced, same as the V1/V3
  # all-new-table probes above.
  defp probe_v4?(prefix) do
    table_exists?(prefix, "phoenix_kit_defect_reasons")
  end

  @doc "Applies the Manufacturing module migration. Accepts a keyword list or map."
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    prefix = normalize_prefix(opts)
    p = prefix_str(prefix)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machine_types (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machine_types_status
    ON #{p}phoenix_kit_machine_types (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machines (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      code VARCHAR(100),
      manufacturer VARCHAR(255),
      serial_number VARCHAR(255),
      description TEXT,
      location_note VARCHAR(500),
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      data JSONB NOT NULL DEFAULT '{}',
      metadata JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machines_status
    ON #{p}phoenix_kit_machines (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machine_type_assignments (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      machine_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_machines (uuid) ON DELETE CASCADE,
      machine_type_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_machine_types (uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_machine_type_assignments_unique
    ON #{p}phoenix_kit_machine_type_assignments (machine_uuid, machine_type_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machine_type_assignments_type
    ON #{p}phoenix_kit_machine_type_assignments (machine_type_uuid)
    """)

    # --- V2: machine passport + soft location link + type field_template ---

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS model VARCHAR(255)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS manufacture_year INTEGER
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS commissioned_on DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS warranty_until DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS to_last_on DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS to_interval_days INTEGER
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS to_next_on DATE
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS notes TEXT
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS location_uuid UUID
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machines
    ADD COLUMN IF NOT EXISTS space_uuid UUID
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machines_location
    ON #{p}phoenix_kit_machines (location_uuid)
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_machine_types
    ADD COLUMN IF NOT EXISTS field_template JSONB NOT NULL DEFAULT '[]'
    """)

    # --- V3: operations directory + machine<->operation M2M with norm override ---

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_operations (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      unit VARCHAR(50),
      base_time_norm_seconds INTEGER,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_operations_status
    ON #{p}phoenix_kit_operations (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_machine_operations (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      machine_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_machines (uuid) ON DELETE CASCADE,
      operation_uuid UUID NOT NULL
        REFERENCES #{p}phoenix_kit_operations (uuid) ON DELETE CASCADE,
      time_norm_seconds INTEGER,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_machine_operations_unique
    ON #{p}phoenix_kit_machine_operations (machine_uuid, operation_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_machine_operations_operation
    ON #{p}phoenix_kit_machine_operations (operation_uuid)
    """)

    # --- V4: defect reasons directory ---

    execute("""
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_defect_reasons (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      data JSONB NOT NULL DEFAULT '{}',
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_defect_reasons_status
    ON #{p}phoenix_kit_defect_reasons (status)
    """)

    # --- V5: migrate machine_type/operation/defect_reason to phoenix_kit_entities ---

    migrate_legacy_directories_to_entities(p, prefix)

    :ok
  end

  @doc """
  Rolling back the Manufacturing module migration is **not supported** —
  this always raises.

  As of V5, `machine_type`/`operation`/`defect_reason` data lives in
  `phoenix_kit_entities`; reconstructing the three dropped tables from
  `phoenix_kit_entity_data` with a guaranteed-correct inverse mapping is
  not attempted. Calling this function blocks rollback of the *entire*
  module (V1 through V5, not just the V5 delta) — `down/1` has always
  been a single all-or-nothing operation with no incremental
  per-version path, so there was no partial-rollback capability to
  preserve. Restore from a pre-V5 database backup instead. Any `opts`
  argument is accepted for call-signature symmetry with `up/1` but is
  not consulted.
  """
  @spec down(keyword() | map()) :: no_return()
  def down(_opts \\ []) do
    raise """
    PhoenixKitManufacturing.Migrations.Machines V5 rollback is not supported.
    machine_type/operation/defect_reason data now lives in phoenix_kit_entities;
    rolling back would require reconstructing three tables from entity_data with
    no guaranteed inverse mapping. Restore from a pre-V5 database backup instead.
    """
  end

  # ── V5: machine_type/operation/defect_reason -> phoenix_kit_entities ──
  #
  # Called once from the end of `up/1` (see the V5 block above). `up/1` is
  # cumulative — every call re-runs the V1/V3/V4 `CREATE TABLE IF NOT
  # EXISTS` statements for the three legacy tables *before* reaching this
  # function, so on a fully-migrated V5 host this silently recreates them
  # empty. This function must therefore re-migrate (a no-op: idempotent —
  # see `insert_if_new/3`) and re-drop them on every call, or a second
  # `mix phoenix_kit.update` run would leave three empty legacy tables
  # behind forever.
  #
  # Order matters (see moduledoc): FK constraints are dropped *before* the
  # join-table rewrite, because `UPDATE ... SET machine_type_uuid = <new
  # entity_data uuid>` would otherwise fail with a foreign-key violation —
  # the new uuid space (`phoenix_kit_entity_data`) is disjoint from the
  # `phoenix_kit_machine_types` uuid space the live FK still points at.

  # Blueprint entity definitions provisioned idempotently by
  # `ensure_blueprint_entity/2`. Order matches the destructuring in
  # `migrate_legacy_directories_to_entities/2`.
  @blueprint_directories [
    %{
      name: "machine_type",
      display_name: "Machine Type",
      display_name_plural: "Machine Types",
      icon: "hero-tag",
      fields_definition: [
        %{
          "type" => "textarea",
          "key" => "description",
          "label" => "Description",
          "translatable" => true
        }
      ],
      translations: %{
        "ru" => %{"display_name" => "Тип станка", "display_name_plural" => "Типы станков"},
        "et" => %{"display_name" => "Masinatüüp", "display_name_plural" => "Masinatüübid"}
      }
    },
    %{
      name: "operation",
      display_name: "Operation",
      display_name_plural: "Operations",
      icon: "hero-clock",
      fields_definition: [
        %{"type" => "text", "key" => "unit", "label" => "Unit"},
        %{
          "type" => "number",
          "key" => "base_time_norm_seconds",
          "label" => "Base time norm (seconds)"
        }
      ],
      translations: %{
        "ru" => %{"display_name" => "Операция", "display_name_plural" => "Операции"},
        "et" => %{"display_name" => "Toiming", "display_name_plural" => "Toimingud"}
      }
    },
    %{
      name: "defect_reason",
      display_name: "Defect Reason",
      display_name_plural: "Defect Reasons",
      icon: "hero-exclamation-triangle",
      fields_definition: [
        %{
          "type" => "textarea",
          "key" => "description",
          "label" => "Description",
          "translatable" => true
        }
      ],
      translations: %{
        "ru" => %{
          "display_name" => "Причина брака",
          "display_name_plural" => "Причины брака"
        },
        "et" => %{"display_name" => "Praagi põhjus", "display_name_plural" => "Praagi põhjused"}
      }
    }
  ]

  defp migrate_legacy_directories_to_entities(p, prefix) do
    creator_uuid = resolve_creator_uuid!()

    [machine_type_entity, operation_entity, defect_reason_entity] =
      Enum.map(@blueprint_directories, &ensure_blueprint_entity(&1, creator_uuid))

    machine_type_mapping =
      migrate_machine_types(
        p,
        machine_type_entity,
        creator_uuid,
        existing_legacy_mapping(machine_type_entity)
      )

    operation_mapping =
      migrate_operations(
        p,
        operation_entity,
        creator_uuid,
        existing_legacy_mapping(operation_entity)
      )

    migrate_defect_reasons(
      p,
      defect_reason_entity,
      creator_uuid,
      existing_legacy_mapping(defect_reason_entity)
    )

    # FK drop before rewrite (see comment above) — otherwise the UPDATEs
    # below fail with a foreign-key violation.
    drop_fk_constraint(p, prefix, "phoenix_kit_machine_type_assignments", "machine_type_uuid")
    drop_fk_constraint(p, prefix, "phoenix_kit_machine_operations", "operation_uuid")

    rewire_references(
      p,
      "phoenix_kit_machine_type_assignments",
      "machine_type_uuid",
      machine_type_mapping
    )

    rewire_references(p, "phoenix_kit_machine_operations", "operation_uuid", operation_mapping)

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_types CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_operations CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_defect_reasons CASCADE")

    :ok
  end

  # `Entities.create_entity/2` and `EntityData.create/2` both require
  # `created_by_uuid` — resolved once up front (rather than relying on
  # their own auto-fill) so a host with zero users fails loudly here with
  # an actionable message instead of a cryptic changeset error three
  # calls deep. Mirrors the `seed_order_status_entities.exs` precedent.
  defp resolve_creator_uuid! do
    Auth.get_first_admin_uuid() || Auth.get_first_user_uuid() ||
      raise """
      PhoenixKitManufacturing.Migrations.Machines V5 requires at least one \
      PhoenixKit user to exist — it is used as created_by_uuid for the \
      machine_type/operation/defect_reason blueprint entities and for any \
      records migrated from the legacy directory tables. Create a user \
      account before running this migration.
      """
  end

  # Idempotent: returns the existing entity by name if the blueprint was
  # already provisioned by an earlier (possibly interrupted) run.
  # Bare "ru"/"et" locale codes for `set_entity_translation/3` follow the
  # `seed_order_status_entities.exs` precedent — a different convention
  # from the BCP-47 dialect codes used inside migrated entity_data below.
  defp ensure_blueprint_entity(spec, creator_uuid) do
    case Entities.get_entity_by_name(spec.name) do
      nil ->
        {:ok, entity} =
          Entities.create_entity(%{
            name: spec.name,
            display_name: spec.display_name,
            display_name_plural: spec.display_name_plural,
            icon: spec.icon,
            fields_definition: spec.fields_definition,
            created_by_uuid: creator_uuid
          })

        Enum.each(spec.translations, fn {lang, attrs} ->
          Entities.set_entity_translation(entity, lang, attrs)
        end)

        entity

      existing ->
        existing
    end
  end

  # Retry-safe seed for the old-uuid -> new-uuid mapping: recovers
  # `%{legacy_uuid => entity_data_uuid}` from records already created by
  # an earlier (possibly interrupted) run, via `metadata["legacy_uuid"]`
  # — *not* from the legacy tables, which may have been dropped and
  # silently recreated empty by V1/V3/V4's `CREATE TABLE IF NOT EXISTS`
  # since that earlier run (see the moduledoc note on `up/1` being
  # cumulative). Without this, a retry after a partial failure could
  # rebuild an empty old->new mapping and leave the join tables pointing
  # at uuids that no longer resolve anywhere.
  defp existing_legacy_mapping(entity) do
    entity.uuid
    |> EntityData.list_by_entity(include_trashed: true)
    |> Enum.reduce(%{}, fn record, acc ->
      case get_in(record.metadata || %{}, ["legacy_uuid"]) do
        legacy_uuid when is_binary(legacy_uuid) -> Map.put(acc, legacy_uuid, record.uuid)
        _ -> acc
      end
    end)
  end

  # Reads `phoenix_kit_machine_types` via raw SQL, not the (deleted, in a
  # later commit) `Schemas.MachineType` Ecto schema — this migration must
  # keep working after that schema no longer exists in the codebase.
  defp migrate_machine_types(p, entity, creator_uuid, mapping) do
    query = """
    SELECT uuid, name, description, status, data, field_template
    FROM #{p}phoenix_kit_machine_types
    """

    PhoenixKit.RepoHelper.repo().query!(query, []).rows
    |> Enum.reduce(mapping, fn [uuid_bin, name, description, status, data, field_template], acc ->
      old_uuid = Ecto.UUID.load!(uuid_bin)

      {title, new_data} =
        data
        |> convert_multilang_data(name, description)
        |> finalize_primary_title(name)

      insert_if_new(acc, old_uuid, %{
        entity_uuid: entity.uuid,
        title: title,
        status: map_legacy_status(status),
        data: new_data,
        metadata: %{"legacy_uuid" => old_uuid, "field_template" => field_template || []},
        created_by_uuid: creator_uuid
      })
    end)
  end

  # Reads `phoenix_kit_operations` via raw SQL — see `migrate_machine_types/4`.
  defp migrate_operations(p, entity, creator_uuid, mapping) do
    query = """
    SELECT uuid, name, unit, base_time_norm_seconds, status, data
    FROM #{p}phoenix_kit_operations
    """

    PhoenixKit.RepoHelper.repo().query!(query, []).rows
    |> Enum.reduce(mapping, fn [uuid_bin, name, unit, base_time_norm_seconds, status, data],
                               acc ->
      old_uuid = Ecto.UUID.load!(uuid_bin)

      {title, new_data} =
        data
        |> convert_multilang_data(name, nil)
        |> finalize_primary_title(name)

      new_data =
        put_primary_extra(new_data, %{
          "unit" => unit,
          "base_time_norm_seconds" => base_time_norm_seconds
        })

      insert_if_new(acc, old_uuid, %{
        entity_uuid: entity.uuid,
        title: title,
        status: map_legacy_status(status),
        data: new_data,
        metadata: %{"legacy_uuid" => old_uuid},
        created_by_uuid: creator_uuid
      })
    end)
  end

  # Reads `phoenix_kit_defect_reasons` via raw SQL — see `migrate_machine_types/4`.
  # The returned mapping is never consulted by the caller (defect_reason
  # has no join table referencing it) but is still threaded through so
  # idempotency (`insert_if_new/3`) works the same way as the other two.
  defp migrate_defect_reasons(p, entity, creator_uuid, mapping) do
    query = """
    SELECT uuid, name, description, status, data
    FROM #{p}phoenix_kit_defect_reasons
    """

    PhoenixKit.RepoHelper.repo().query!(query, []).rows
    |> Enum.reduce(mapping, fn [uuid_bin, name, description, status, data], acc ->
      old_uuid = Ecto.UUID.load!(uuid_bin)

      {title, new_data} =
        data
        |> convert_multilang_data(name, description)
        |> finalize_primary_title(name)

      insert_if_new(acc, old_uuid, %{
        entity_uuid: entity.uuid,
        title: title,
        status: map_legacy_status(status),
        data: new_data,
        metadata: %{"legacy_uuid" => old_uuid},
        created_by_uuid: creator_uuid
      })
    end)
  end

  # Creates the `EntityData` row unless `old_uuid` is already a key in
  # `mapping` (either recovered by `existing_legacy_mapping/1` or created
  # earlier in this same pass) — the idempotency check spec §2 п.2 calls
  # for. Returns `mapping` with `old_uuid => new_uuid` present either way.
  defp insert_if_new(mapping, old_uuid, attrs) do
    if Map.has_key?(mapping, old_uuid) do
      mapping
    else
      {:ok, record} = EntityData.create(attrs)
      Map.put(mapping, old_uuid, record.uuid)
    end
  end

  # `"active"`/`"inactive"` are the only two values the legacy schemas'
  # `@statuses` allow; anything else (there shouldn't be any) defensively
  # maps to `"draft"` rather than the more privileged `"published"`.
  defp map_legacy_status("active"), do: "published"
  defp map_legacy_status(_other), do: "draft"

  # Converts the legacy `data` JSONB shape to the entities shape.
  #
  # Multilang case (finding #1/#2): every lang block (primary and
  # secondary) is copied as-is except `_name` -> `_title`; `_description`
  # is untouched (already declared `translatable` in `fields_definition`
  # — see `@blueprint_directories`); `_primary_language` is copied as-is.
  #
  # Flat case (Languages module was never enabled for this row, or the
  # row predates any multilang save): the primary block is built fresh
  # from the plain `name`/`description` columns, keyed under the
  # *current* `Multilang.primary_language/0` — there is no embedded
  # primary language code to preserve.
  defp convert_multilang_data(old_data, old_name, old_description) do
    if Multilang.multilang_data?(old_data) do
      rename_translatable_blocks(old_data)
    else
      primary = Multilang.primary_language()
      primary_block = %{"_title" => old_name} |> put_present("_description", old_description)
      %{"_primary_language" => primary, primary => primary_block}
    end
  end

  defp rename_translatable_blocks(old_data) do
    Map.new(old_data, fn
      {"_primary_language", lang} -> {"_primary_language", lang}
      {lang_code, block} when is_map(block) -> {lang_code, rename_name_to_title(block)}
      {key, value} -> {key, value}
    end)
  end

  defp rename_name_to_title(block) do
    case Map.get(block, "_name") do
      nil -> Map.delete(block, "_name")
      title -> block |> Map.delete("_name") |> Map.put("_title", title)
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Guarantees the primary-language block carries an explicit `_title`
  # (falling back to the legacy flat `name` column when the multilang
  # data had no `_name` override on its primary block) and returns that
  # resolved title alongside the updated data map — `EntityData.create/2`
  # requires both, and they must never disagree.
  defp finalize_primary_title(data_map, fallback_title) do
    primary = data_map["_primary_language"]
    block = Map.get(data_map, primary, %{})
    title = block["_title"] || fallback_title
    {title, Map.put(data_map, primary, Map.put(block, "_title", title))}
  end

  # Adds non-translatable plain fields (operation's `unit` /
  # `base_time_norm_seconds`) to the primary-language block only, without
  # a `_` prefix (finding #2) — `nil` values are omitted rather than
  # stored, since neither field is required by `fields_definition`.
  defp put_primary_extra(data_map, extra) do
    primary = data_map["_primary_language"]
    clean_extra = extra |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    if map_size(clean_extra) == 0 do
      data_map
    else
      Map.update!(data_map, primary, &Map.merge(&1, clean_extra))
    end
  end

  # Discovers the live FK constraint name for `table.column` via the
  # catalog rather than assuming a `..._fkey` naming convention — reused
  # by `probe_v5?/1` in a later commit. Returns `nil` when no such
  # constraint exists (already dropped, e.g. on a retry).
  @spec fk_constraint_name(String.t(), String.t(), String.t()) :: String.t() | nil
  defp fk_constraint_name(prefix, table, column) do
    query = """
    SELECT tc.constraint_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON tc.constraint_name = kcu.constraint_name
     AND tc.table_schema = kcu.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = $1
      AND tc.table_name = $2
      AND kcu.column_name = $3
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix || "public", table, column]) do
      {:ok, %{rows: [[name] | _]}} -> name
      _ -> nil
    end
  end

  defp drop_fk_constraint(p, prefix, table, column) do
    case fk_constraint_name(prefix, table, column) do
      nil -> :ok
      name -> execute("ALTER TABLE #{p}#{table} DROP CONSTRAINT IF EXISTS #{name}")
    end
  end

  # Parameterized `UPDATE` (not `execute/1`, which has no bind-param
  # support) — uuid columns round-trip through `Ecto.UUID.dump!/1` since
  # raw Postgrex encodes/decodes `uuid` as a 16-byte binary, not the
  # dashed string form every uuid in `mapping` is already in.
  defp rewire_references(p, table, column, mapping) do
    Enum.each(mapping, fn {old_uuid, new_uuid} ->
      PhoenixKit.RepoHelper.repo().query!(
        "UPDATE #{p}#{table} SET #{column} = $2 WHERE #{column} = $1",
        [Ecto.UUID.dump!(old_uuid), Ecto.UUID.dump!(new_uuid)]
      )
    end)
  end

  # Core passes a keyword list (`prefix: "public", version: 1`); the legacy
  # mechanism used a map (`%{prefix: "public"}`). Support both.
  defp normalize_prefix(opts) when is_list(opts), do: opts[:prefix] || "public"
  defp normalize_prefix(%{prefix: prefix}), do: prefix || "public"
  defp normalize_prefix(_), do: "public"

  defp prefix_str(prefix) when prefix in [nil, "public"], do: ""
  defp prefix_str(prefix), do: "#{prefix}."

  # Whether `table` exists under `prefix`. Generalizes the `to_regclass`
  # presence check every version probe is built from. Never raises on a
  # missing schema/table — `to_regclass` returns NULL, not an error.
  @spec table_exists?(String.t(), String.t()) :: boolean()
  defp table_exists?(prefix, table) do
    qualified = if prefix == "public", do: "public.#{table}", else: "#{prefix}.#{table}"

    case PhoenixKit.RepoHelper.repo().query("SELECT to_regclass($1)", [qualified]) do
      {:ok, %{rows: [[nil]]}} -> false
      {:ok, %{rows: [[_oid]]}} -> true
      _ -> false
    end
  end

  # Whether `column` exists on `table` under `prefix`. Backs every
  # structural-addition probe from V2 onward (`table_exists?/2` alone can't
  # distinguish "table exists at an older version" from "table has this
  # version's new column").
  @spec column_exists?(String.t(), String.t(), String.t()) :: boolean()
  defp column_exists?(prefix, table, column) do
    query = """
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix, table, column]) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  end
end
