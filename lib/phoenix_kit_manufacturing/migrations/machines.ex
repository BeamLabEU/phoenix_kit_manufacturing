defmodule PhoenixKitManufacturing.Migrations.Machines do
  @moduledoc """
  Versioned migration for the Manufacturing module.

  Creates the machines reference-book tables:

    * `phoenix_kit_machines`
    * `phoenix_kit_machine_types`
    * `phoenix_kit_machine_type_assignments` (join)

  All statements use `IF NOT EXISTS` guards — safe to run multiple times.

  Implements the versioned-migration protocol expected by PhoenixKit Core
  (`mix phoenix_kit.update`): `current_version/0` and
  `migrated_version_runtime/1`. The host applies these by running
  `mix phoenix_kit.update`, which discovers this module via
  `PhoenixKitManufacturing.migration_module/0`, diffs the applied version
  against `current_version/0`, and generates + runs a wrapper migration.
  Reference implementation — `PhoenixKit.Migrations.Postgres` in Core.

  Depends on `uuid_generate_v7()`, provided by core's early migrations.
  """

  use Ecto.Migration

  @current_version 1

  @doc "Target schema version of the Manufacturing module."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Currently applied schema version, read from the database.

  Returns `0` when the `phoenix_kit_machines` table does not yet exist, and
  `#{@current_version}` once it has been created. `opts` is a keyword list
  with an optional `:prefix`.
  """
  @spec migrated_version_runtime(keyword() | map()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    prefix = normalize_prefix(opts)

    table =
      if prefix == "public",
        do: "public.phoenix_kit_machines",
        else: "#{prefix}.phoenix_kit_machines"

    case PhoenixKit.RepoHelper.repo().query("SELECT to_regclass($1)", [table]) do
      {:ok, %{rows: [[nil]]}} -> 0
      {:ok, %{rows: [[_oid]]}} -> @current_version
      _ -> 0
    end
  rescue
    _ -> 0
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

    :ok
  end

  @doc "Rolls back the Manufacturing module migration. Accepts a keyword list or map."
  @spec down(keyword() | map()) :: :ok
  def down(opts \\ []) do
    p = prefix_str(normalize_prefix(opts))

    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_type_assignments CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machines CASCADE")
    execute("DROP TABLE IF EXISTS #{p}phoenix_kit_machine_types CASCADE")

    :ok
  end

  # Core passes a keyword list (`prefix: "public", version: 1`); the legacy
  # mechanism used a map (`%{prefix: "public"}`). Support both.
  defp normalize_prefix(opts) when is_list(opts), do: opts[:prefix] || "public"
  defp normalize_prefix(%{prefix: prefix}), do: prefix || "public"
  defp normalize_prefix(_), do: "public"

  defp prefix_str(prefix) when prefix in [nil, "public"], do: ""
  defp prefix_str(prefix), do: "#{prefix}."
end
