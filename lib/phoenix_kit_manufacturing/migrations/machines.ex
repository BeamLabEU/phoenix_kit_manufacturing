defmodule PhoenixKitManufacturing.Migrations.Machines do
  @moduledoc """
  Versioned migration for the Manufacturing module.

  Creates and extends the machines reference-book tables:

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
    * `phoenix_kit_machine_types` — machine type records.
      * V1: `name`, `description`, `status`, `data`.
      * V2: `field_template` (JSONB array, default `[]`) — the per-type
        dynamic metadata field definitions rendered on the machine form.
    * `phoenix_kit_machine_type_assignments` (join, V1 only).
    * `phoenix_kit_operations` (V3) — global operation directory: `name`,
      `unit`, `base_time_norm_seconds`, `status`, `data`.
    * `phoenix_kit_machine_operations` (join, V3) — machine<->operation
      linking with an optional per-machine `time_norm_seconds` override
      (`NULL` means "use the operation's `base_time_norm_seconds`"),
      unique on `(machine_uuid, operation_uuid)`, both FKs
      `ON DELETE CASCADE`.
    * `phoenix_kit_defect_reasons` (V4) — global defect-reason directory:
      `name`, `description`, `status`, `data`. A plain reference book, not
      linked (M2M or otherwise) to machines/operations in this wave.

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

  `down/1` is a full, all-or-nothing rollback of everything this module has
  ever created: it drops all six tables (`CASCADE`), which necessarily
  takes every version's columns down with them. It does **not** support
  incremental, per-version rollback — there is no "V2 -> V1, keeping V1
  data intact" path. Any `:version` key in `opts` is accepted for
  call-signature symmetry with `up/1` but is not consulted.
  """

  use Ecto.Migration

  @disable_ddl_transaction true

  @current_version 4

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
    p = prefix_str(normalize_prefix(opts))

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

    :ok
  end

  @doc """
  Rolls back the Manufacturing module migration. Accepts a keyword list or
  map.

  This is a full, all-or-nothing rollback: it drops every table this
  module has ever created (`CASCADE`), across every version — which
  necessarily takes every version's columns down with them (dropping
  `phoenix_kit_machines` removes its V2 passport columns; there is no
  standalone `DROP COLUMN` step). It does **not** support incremental,
  per-version rollback — there is no "V2 -> V1, keeping V1 data intact"
  path. Any `:version` key in `opts` is accepted for call-signature
  symmetry with `up/1` but is not read.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    p = prefix_str(normalize_prefix(opts))

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_type_assignments CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_operations CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machines CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_types CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_operations CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_defect_reasons CASCADE")

    :ok
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
