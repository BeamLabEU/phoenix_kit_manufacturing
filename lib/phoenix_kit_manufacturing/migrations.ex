defmodule PhoenixKitManufacturing.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_manufacturing` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`. This follows the canonical shape
  documented in `phoenix_kit_hello_world`'s README ("Versioned migrations",
  "Adopting a table core already creates") and its
  `mix phoenix_kit_hello_world.audit_migrations` task: **two readers**
  (`migrated_version/1` for migration context, `migrated_version_runtime/1`
  for Mix-task context), `up/1` re-reading the version before it changes
  anything, and a namespaced `COMMENT ON TABLE` marker on one anchor table.
  `PhoenixKitCustomerSupport.Migrations` is the closest sibling example of
  this exact adoption situation.

  ## Ownership situation — read before touching

  All 3 `phoenix_kit_machine*` tables are core's baseline: `V144`
  consolidated them (they used to be created by this module's own,
  since-deleted `migration_module/0` — see `git show
  c8d0269^:lib/phoenix_kit_manufacturing/migrations/machines.ex`) into
  their current, final shape. On every existing install all 3 already have
  their full current shape before this chain ever executes — this is an
  ADOPTION, not a create. Varchar widths are never restated as a second
  number: `PhoenixKitManufacturing.Schemas.Machine.column_widths/0` is the
  single shape authority this chain's DDL interpolates (the join tables
  `MachineTypeAssignment`/`MachineOperation` have no varchar column of
  their own).

  The chain anchors its version marker on `phoenix_kit_machines` — this
  module's own central, load-bearing table (same reasoning
  `PhoenixKitCustomerSupport.Migrations` used to pick `phoenix_kit_tickets`
  over a leaf table): both join tables carry a real FK back to
  `phoenix_kit_machines(uuid) ON DELETE CASCADE`, so it is the one table at
  risk of being dropped independently that every other adoption in this
  chain ultimately depends on.

  ### No FK on the soft references — read before "fixing" this

  `phoenix_kit_machine_type_assignments.machine_type_uuid` and
  `phoenix_kit_machine_operations.operation_uuid` point at
  `phoenix_kit_entity_data.uuid`, a table owned by the separate
  `phoenix_kit_entities` package — machine types and operations moved
  there (see `PhoenixKitManufacturing.EntitiesRegistry`). Naively reading
  core's `v144.ex` `CREATE TABLE` text, both columns look like plain `uuid
  NOT NULL` with nothing stopping an FK from being added — but `v144.ex`
  also calls `drop_fk_constraint/4` on both columns unconditionally right
  after creating each join table, because a host upgrading from the
  published `phoenix_kit_manufacturing` 0.2.0 (module V1) has a *live* FK
  there (pointing at the old `phoenix_kit_machine_types`/
  `phoenix_kit_operations` directory tables). Core's actual, real behavior
  — CREATE TABLE, then unconditionally drop any FK on these two columns —
  has **no** FK on either column in its final state. This chain's V1
  matches that real behavior exactly: **no `fk_guard` call for
  `machine_type_uuid` or `operation_uuid`, anywhere.** This is not a
  documented deviation from core (unlike
  `PhoenixKitCustomerSupport.Migrations`' `changed_by_uuid` situation) —
  core's real behavior and this chain's V1 agree perfectly. It would only
  look like a deviation to a reader who stopped at the `CREATE TABLE` text
  without accounting for the drop step that follows it. Do not "fix" this
  by adding the FK back.

  There is no other discrepancy anywhere — V144's source, core's
  `ExpectedSchema` manifest, and a live fully-migrated database all agree
  on all 3 tables' full shape today: every column's type, default, and
  nullability (the manifest's authoritative `revisions` field, not its
  `create:` ADD-COLUMN text, which — being a repair-path fragment —
  omits `NOT NULL` on a handful of columns that are in fact non-null;
  the tests below compare against `revisions`, not `create:`). This is a
  clean Phase-0 adoption: V1 changes NOTHING except stamping the marker.

  ### Phase 0 — this V1 adopts, and changes NOTHING

  `CREATE TABLE IF NOT EXISTS` shape-identical to core's `V144` baseline,
  under core's exact object names (every pkey, every index, the 2 real
  FKs), then a **namespaced** marker stamp on the anchor table
  (`pkm_schema:1` — an adopted table may already carry a foreign comment,
  so the reader must treat prose as version 0, never crash on it, never
  assume it means V1). The old, published 0.2.0 module never actually
  wrote a `COMMENT ON TABLE` marker at all — its migrations used
  structural column/table-existence probing instead — so no real host
  carries a stray bare-number comment from this module's own history, but
  the defensive "any non-namespaced comment reads as 0" behavior is still
  required by the general protocol (a table that happens to carry someone
  else's prose comment, or a bare number from some unrelated tool, must
  never be misread as our own version).

  Because the shape is unchanged, core's `ExpectedSchema` manifest stays
  accurate for every column of all 3 tables: **no core release is required
  and there is no release-ordering hazard.** This package releases alone.

  `phoenix_kit_machines` additionally carries `CREATE TABLE IF NOT EXISTS`
  for its FULL 22-column shape at once (Phase 2 below) **and** the same 10
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements core's `v144.ex`
  ships as a safety net for a host whose table still only has the old
  module-owned V1 12-column shape. This double coverage is deliberate: on
  every install running today one of the two is always a no-op, but which
  one depends on which shape the table already has.

  ### Phase 1 — the first real shape change (V2+) is when core must move too

  Before shipping a version that changes any of the 3 tables' shape:

    1. add the objects that version alters to core's manifest generator's
       `@excluded_exact` (`dev_docs/squash/generate_baseline.exs`) and
       regenerate `ExpectedSchema`;
    2. raise this package's `:phoenix_kit` floor to the release that ships
       that regenerated manifest.

  Skipping step 1 means `mix phoenix_kit.repair` restores the old shape
  after every run, silently undoing the new version.

  ### Phase 2 — creation leaves core's baseline at the next squash cycle

  When core cuts its next baseline, module-owned tables are simply not
  included: fresh installs from then on get all 3 `phoenix_kit_machine*`
  tables from THIS chain's V1 — which is why V1's `up/1` ensures the
  `uuid_generate_v7()` function (and its `pgcrypto` extension) exist rather
  than assuming core's chain already provided them, and why the `CREATE
  TABLE` statements must already be the full, correct definition on their
  own, not merely a shape-matching no-op for an already-existing table.
  Existing installs are untouched — a baseline squash only affects fresh
  installs and below-floor bridging.

  ## What must NEVER happen

  No conditional core migration of the form "module absent → drop the
  tables" — that is nondeterministic (depends on which packages are
  compiled in) and destroys data on a host that merely removed the
  package. Removing this module's data is a human, manual step — see
  README.md "Removing this module" for the operator SQL. There is
  deliberately no automated uninstall path, and `down/1` NEVER drops any of
  the 3 tables for ANY target version, including `0` — it only unstamps (or
  re-stamps) the marker on the anchor table. The rows are every host's
  real machine reference-book records and their type/operation links;
  rolling back this module's chain must not destroy any of them.

  The migrated version is tracked as a `pkm_schema:<N>` COMMENT on
  `phoenix_kit_machines`. A marker-less table, or one carrying a foreign
  (non-`pkm_schema:`) comment, reads as version 0 — the core-baseline shape
  before this chain existed.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKitManufacturing.Schemas.Machine

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @marker_prefix "pkm_schema:"

  @machines "phoenix_kit_machines"
  @type_assignments "phoenix_kit_machine_type_assignments"
  @operations "phoenix_kit_machine_operations"

  # The single table this chain's marker lives on — this module's own hub
  # table, not one of the join tables (see the moduledoc for why). Every
  # other table adopted below shares this chain's version; neither join
  # table carries a marker of its own.
  @version_table @machines

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The version a bare, freshly-created set of tables is at (Phase 2 — a
  future install whose core baseline no longer creates these tables).
  """
  @spec initial_version() :: pos_integer()
  def initial_version, do: @initial_version

  @doc """
  The table carrying the `pkm_schema:<N>` marker for the whole 3-table chain.

  Not part of the protocol `mix phoenix_kit.update` calls. Exported so an
  auditor (`mix phoenix_kit_hello_world.audit_migrations`) can verify the
  marker is really a number without hard-coding this table's name.
  """
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  Applies every chain version up to `opts[:version]` (default
  `current_version/0`). Migration-context only — re-reads the installed
  version via `migrated_version/1` before making any change, so a database
  already at (or ahead of) the target does nothing.
  """
  @spec up(keyword() | map()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)

    if migrated_version(opts) < opts.version do
      # Don't assume core's chain ran first (Phase 2): `uuid_generate_v7()`
      # is built on pgcrypto's `gen_random_bytes`, and
      # `ensure_uuid_v7_function/1` does not install extensions — without
      # the first call the function is created and then fails on the first
      # insert.
      Helpers.ensure_extension!("pgcrypto")
      Helpers.ensure_uuid_v7_function(opts.prefix)

      opts.prefix
      |> up_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  Rolls back to `opts[:version]` (default `0`). Migration-context only.
  Never drops a table or a row in any of the 3, for any target — see the
  moduledoc.
  """
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)

    if migrated_version(opts) > opts.version do
      opts.prefix
      |> down_statements(opts.version)
      |> Enum.each(&execute/1)
    end

    :ok
  end

  @doc """
  The version currently installed, read INSIDE a migration — through
  `Ecto.Migration`'s own `repo()`. No rescue: inside a migration a version
  that cannot be read must abort the transaction, never be guessed at.
  `up/1` and `down/1` call this — never `migrated_version_runtime/1` —
  before making any change.
  """
  @spec migrated_version(keyword() | map()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.prefix)
  end

  @doc """
  Runtime-safe reader — the one `mix phoenix_kit.update` calls, from a Mix
  task with no migrator running, through PhoenixKit's configured repo
  instead of `Ecto.Migration`'s.

  An invalid prefix is re-raised, matching core's own reader: `0` means
  "not installed here", so reporting it for a bad prefix would tell the
  operator something false and send the updater off to install a schema
  over live data. Genuine unreachability still yields `0`, which is safe
  only because `up/1` re-reads the version in migration context before
  touching anything — a wrong `0` costs a redundant migration file, never
  wrong DDL.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.prefix)
  rescue
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test suite parses these statements to prove that the object
  names are core's `V144` names, that the `CREATE TABLE` stays
  shape-identical to core's `ExpectedSchema` manifest, that every varchar
  width is `Machine.column_widths/0`, that neither soft reference ever
  gets an FK, and that nothing here can drop a table.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `0` applies nothing (not an operation — clearing
  the marker is `down/1`'s job); `1` is the pure `V144`-adoption step
  across all 3 tables.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ @default_prefix, target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)

    if target == 0 do
      []
    else
      v1_statements(prefix, target)
    end
  end

  @doc """
  The SQL `down/1` executes, as data (marker bookkeeping only, on the
  anchor table). V1 changes no shape of its own — it is pure adoption — so
  there is nothing to drop beyond the marker; all 3 tables and every row in
  them are left untouched, for any target including `0`.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ @default_prefix, target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix)
    qualified = Helpers.qualify_table(@version_table, prefix)

    if target > 0 do
      ["COMMENT ON TABLE #{qualified} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{qualified} IS NULL"]
    end
  end

  # ── V1 statement builder ────────────────────────────────────────────────

  defp v1_statements(prefix, target) do
    uuid_default = Helpers.uuid_v7_call(prefix)
    w = Machine.column_widths()

    q_machines = Helpers.qualify_table(@machines, prefix)
    q_type_assignments = Helpers.qualify_table(@type_assignments, prefix)
    q_operations = Helpers.qualify_table(@operations, prefix)

    tables = [
      """
      CREATE TABLE IF NOT EXISTS #{q_machines} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "name" character varying(#{w.name}) NOT NULL,
        "code" character varying(#{w.code}),
        "manufacturer" character varying(#{w.manufacturer}),
        "serial_number" character varying(#{w.serial_number}),
        "description" text,
        "location_note" character varying(#{w.location_note}),
        "status" character varying(#{w.status}) DEFAULT 'active'::character varying NOT NULL,
        "data" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "model" character varying(#{w.model}),
        "manufacture_year" integer,
        "commissioned_on" date,
        "warranty_until" date,
        "to_last_on" date,
        "to_interval_days" integer,
        "to_next_on" date,
        "notes" text,
        "location_uuid" uuid,
        "space_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_type_assignments} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "machine_uuid" uuid NOT NULL,
        "machine_type_uuid" uuid NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{q_operations} (
        "uuid" uuid DEFAULT #{uuid_default} NOT NULL,
        "machine_uuid" uuid NOT NULL,
        "operation_uuid" uuid NOT NULL,
        "time_norm_seconds" integer,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """
    ]

    # Safety net for a host whose phoenix_kit_machines still carries only
    # the old module-owned V1 12-column shape — mirrors core's own
    # v144.ex, which ships the identical 10 ADD COLUMN IF NOT EXISTS
    # statements for the same reason (see moduledoc "Phase 0"). The CREATE
    # TABLE above already has the full 22-column shape for Phase 2, so on
    # every install running today one of the two is always a no-op —
    # deliberate double coverage, not redundancy.
    alter_safety_net = [
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"model\" character varying(#{w.model})",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"manufacture_year\" integer",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"commissioned_on\" date",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"warranty_until\" date",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"to_last_on\" date",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"to_interval_days\" integer",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"to_next_on\" date",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"notes\" text",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"location_uuid\" uuid",
      "ALTER TABLE #{q_machines} ADD COLUMN IF NOT EXISTS \"space_uuid\" uuid"
    ]

    pkeys =
      for {table, qualified} <- [
            {@machines, q_machines},
            {@type_assignments, q_type_assignments},
            {@operations, q_operations}
          ] do
        pkey_guard(table, qualified, prefix)
      end

    indexes =
      [
        {"", "idx_machines_status", q_machines, "btree", "status"},
        {"", "idx_machines_location", q_machines, "btree", "location_uuid"},
        {"UNIQUE", "idx_machine_type_assignments_unique", q_type_assignments, "btree",
         "machine_uuid, machine_type_uuid"},
        {"", "idx_machine_type_assignments_type", q_type_assignments, "btree",
         "machine_type_uuid"},
        {"UNIQUE", "idx_machine_operations_unique", q_operations, "btree",
         "machine_uuid, operation_uuid"},
        {"", "idx_machine_operations_operation", q_operations, "btree", "operation_uuid"}
      ]
      |> Enum.map(fn {unique, name, table, method, columns} ->
        "CREATE #{unique_prefix(unique)}INDEX IF NOT EXISTS #{name} ON #{table} USING #{method} (#{columns})"
      end)

    # Only the real, hard `machine_uuid` FK back into `phoenix_kit_machines`
    # is adopted here — `machine_type_uuid`/`operation_uuid` are soft
    # references with NO FK, by design. See the moduledoc's "No FK on the
    # soft references" section before adding one.
    fks = [
      fk_guard(
        @type_assignments,
        q_type_assignments,
        "phoenix_kit_machine_type_assignments_machine_uuid_fkey",
        "machine_uuid",
        q_machines,
        "CASCADE",
        prefix
      ),
      fk_guard(
        @operations,
        q_operations,
        "phoenix_kit_machine_operations_machine_uuid_fkey",
        "machine_uuid",
        q_machines,
        "CASCADE",
        prefix
      )
    ]

    marker = ["COMMENT ON TABLE #{q_machines} IS '#{@marker_prefix}#{target}'"]

    tables ++ alter_safety_net ++ pkeys ++ indexes ++ fks ++ marker
  end

  defp unique_prefix("UNIQUE"), do: "UNIQUE "
  defp unique_prefix(""), do: ""

  defp pkey_guard(table, qualified, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{table}_pkey'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (uuid);
      END IF;
    END
    $$
    """
  end

  defp fk_guard(table, qualified, constraint_name, column, references, on_delete, prefix) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{qualified} ADD CONSTRAINT #{constraint_name} FOREIGN KEY (#{column}) REFERENCES #{references}(uuid) ON DELETE #{on_delete};
      END IF;
    END
    $$
    """
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{})
    prefix = validated_prefix(Map.get(opts, :prefix) || @default_prefix)

    opts
    |> Map.put(:prefix, prefix)
    |> Map.put_new(:version, version)
  end

  defp read_version(repo, prefix) do
    if table_exists?(repo, prefix) do
      repo |> table_comment(prefix) |> parse_version()
    else
      0
    end
  end

  defp table_exists?(repo, prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = $1 AND table_schema = $2
    )
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[exists?]]}} -> exists?
      {:error, error} -> raise error
    end
  end

  defp table_comment(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = $1 AND n.nspname = $2
    """

    case repo.query(query, [@version_table, prefix], log: false) do
      {:ok, %{rows: [[comment]]}} -> comment
      {:ok, %{rows: []}} -> nil
      {:error, error} -> raise error
    end
  end

  defp parse_version(@marker_prefix <> n) do
    case Integer.parse(n) do
      {version, ""} when version >= 0 -> version
      _ -> 0
    end
  end

  defp parse_version(_), do: 0

  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitManufacturing.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  # `phoenix_kit` is a normal (non-optional) dependency of this package, so
  # `Helpers` is always loaded — unlike customer_support's fallback branch,
  # there is no configuration where this module compiles without it.
  defp validated_prefix(prefix) do
    Helpers.validate_prefix!(prefix)
    prefix
  end
end
