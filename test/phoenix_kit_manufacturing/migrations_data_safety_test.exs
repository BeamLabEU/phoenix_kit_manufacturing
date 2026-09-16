defmodule PhoenixKitManufacturing.MigrationsDataSafetyTest do
  use PhoenixKitManufacturing.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitManufacturing.Machines
  alias PhoenixKitManufacturing.Migrations
  alias PhoenixKitManufacturing.Schemas.{Machine, MachineOperation, MachineTypeAssignment}

  @moduledoc """
  The acceptance a table full of real machines actually needs, and that no
  static test can give: REAL rows, a REAL `down/1` run as a migration, and
  the rows still there afterwards, byte-for-byte.

  `migrations_test.exs` proves what the chain BUILDS (no
  DROP/TRUNCATE/DELETE token anywhere, `down/1` emits marker bookkeeping
  only). That is a proof about text. This file proves what the chain DOES to
  a database that holds a real machine, a real type assignment, and a real
  operation link — on `phoenix_kit_machines`, the anchor table, and its two
  join-table dependents. `machine_type_uuid`/`operation_uuid` are soft
  references (see `Migrations`' moduledoc), so a random `Ecto.UUID.generate()`
  is a perfectly real value for them — there is no FK to violate.

  The last test is the mutation check: it runs the same survival harness
  against a deliberately destructive rollback and requires it to FAIL.
  Without that, a survival assertion that silently stopped asserting (wrong
  table name, empty row set) would stay green forever and prove nothing.

  `async: false` — the migrator wants the shared sandbox connection.
  """

  defmodule RollbackToZero do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.down(prefix: "public", version: 0)
    def down, do: :ok
  end

  defmodule RollbackToOneFromMap do
    @moduledoc false
    use Ecto.Migration

    # Deliberately the MAP shape: it is accepted, so it must carry
    # `:version` like the keyword list does.
    def up, do: Migrations.down(%{prefix: "public", version: 1})
    def down, do: :ok
  end

  defmodule DestructiveRollback do
    @moduledoc false
    use Ecto.Migration

    # NOT what the package ships — the mutant the survival check must catch.
    def up do
      execute("DELETE FROM public.phoenix_kit_machine_operations")
      execute("DELETE FROM public.phoenix_kit_machine_type_assignments")
      execute("DELETE FROM public.phoenix_kit_machines")
    end

    def down, do: :ok
  end

  defmodule RunUpToOne do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(prefix: "public", version: 1)
    def down, do: :ok
  end

  setup do
    {:ok, machine} = Machines.create_machine(%{name: "Data safety machine"})

    type_uuid = Ecto.UUID.generate()
    {:ok, :synced} = Machines.sync_machine_types(machine.uuid, [type_uuid])
    assignment = Repo.get_by!(MachineTypeAssignment, machine_uuid: machine.uuid)

    operation_uuid = Ecto.UUID.generate()
    {:ok, :synced} = Machines.sync_machine_operations(machine.uuid, %{operation_uuid => 120})
    operation = Repo.get_by!(MachineOperation, machine_uuid: machine.uuid)

    {:ok, machine: machine, assignment: assignment, operation: operation}
  end

  test "a real down(version: 0) leaves the seeded machine, type assignment and operation link alive",
       %{machine: machine, assignment: assignment, operation: operation} do
    machine_count = count("phoenix_kit_machines")
    assignment_count = count("phoenix_kit_machine_type_assignments")
    operation_count = count("phoenix_kit_machine_operations")

    run_migration(RollbackToZero)

    assert count("phoenix_kit_machines") == machine_count,
           "rolling this chain back changed the row count in phoenix_kit_machines"

    assert count("phoenix_kit_machine_type_assignments") == assignment_count,
           "rolling this chain back changed the row count in phoenix_kit_machine_type_assignments"

    assert count("phoenix_kit_machine_operations") == operation_count,
           "rolling this chain back changed the row count in phoenix_kit_machine_operations"

    reloaded_machine = Repo.get!(Machine, machine.uuid)
    assert reloaded_machine.name == machine.name
    assert reloaded_machine.status == machine.status

    reloaded_assignment = Repo.get!(MachineTypeAssignment, assignment.uuid)
    assert reloaded_assignment.machine_uuid == assignment.machine_uuid
    assert reloaded_assignment.machine_type_uuid == assignment.machine_type_uuid

    reloaded_operation = Repo.get!(MachineOperation, operation.uuid)
    assert reloaded_operation.machine_uuid == operation.machine_uuid
    assert reloaded_operation.operation_uuid == operation.operation_uuid
    assert reloaded_operation.time_norm_seconds == operation.time_norm_seconds
  end

  test "the rollback still does its one real job: the marker is cleared" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_machines IS 'pkm_schema:1'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    run_migration(RollbackToZero)

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "a rollback to version 1 passed as a map stops at 1, not at 0" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_machines IS 'pkm_schema:1'")

    run_migration(RollbackToOneFromMap)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1,
           "the map shape lost :version and rolled the chain further back than asked"
  end

  test "a real up(version: 1) run is idempotent and leaves seeded rows untouched",
       %{machine: machine, assignment: assignment, operation: operation} do
    # up/1 re-reads the installed version, calls ensure_extension!/1 and
    # ensure_uuid_v7_function/1, then runs the same guarded statements
    # up_statements/2 emits — clearing the marker first simulates the
    # "database behind the target" branch up/1 checks before doing anything,
    # so this exercises that whole path for real rather than as SQL text
    # applied directly (test_helper.exs does the latter, once, before any
    # test runs — this is the only place up/1 itself, as a function, gets a
    # real migration-context run).
    machine_count = count("phoenix_kit_machines")
    assignment_count = count("phoenix_kit_machine_type_assignments")
    operation_count = count("phoenix_kit_machine_operations")

    Repo.query!("COMMENT ON TABLE phoenix_kit_machines IS NULL")

    run_migration(RunUpToOne)

    assert Migrations.migrated_version_runtime(prefix: "public") == 1

    assert count("phoenix_kit_machines") == machine_count,
           "a real up(version: 1) run changed the row count in phoenix_kit_machines"

    assert count("phoenix_kit_machine_type_assignments") == assignment_count,
           "a real up(version: 1) run changed the row count in phoenix_kit_machine_type_assignments"

    assert count("phoenix_kit_machine_operations") == operation_count,
           "a real up(version: 1) run changed the row count in phoenix_kit_machine_operations"

    assert Repo.get!(Machine, machine.uuid).name == machine.name

    assert Repo.get!(MachineTypeAssignment, assignment.uuid).machine_type_uuid ==
             assignment.machine_type_uuid

    assert Repo.get!(MachineOperation, operation.uuid).operation_uuid == operation.operation_uuid

    # Idempotence: every table/pkey/index/fk statement is
    # CREATE-IF-NOT-EXISTS/DO-guarded against objects that already exist
    # (core's baseline created them), so running up/1 again must be a no-op,
    # not an error.
    run_migration(RunUpToOne)
    assert Migrations.migrated_version_runtime(prefix: "public") == 1
  end

  test "the survival check has teeth: a destructive rollback fails it", %{machine: machine} do
    machine_count = count("phoenix_kit_machines")

    run_migration(DestructiveRollback)

    # The same assertions the real test makes. Both must fail here, or the
    # real test above is decoration.
    assert_raise ExUnit.AssertionError, fn ->
      assert count("phoenix_kit_machines") == machine_count
    end

    assert_raise Ecto.NoResultsError, fn ->
      Repo.get!(Machine, machine.uuid)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Runs the migration IN THIS PROCESS, through Ecto's own migration runner,
  # rather than `Ecto.Migrator.up/4`. The Migrator runs the migration inside a
  # `Task`, which then has to check out the sandbox connection this test
  # already owns — it never gets it, and every assertion below dies in the
  # checkout queue instead of testing the rollback. The runner is what the
  # Migrator itself calls once it has dealt with locking and version
  # bookkeeping; going straight to it keeps the real migration context (so
  # `execute/1` inside `down/1` is the real `execute/1`) and drops only the
  # parts this file is not about.
  defp run_migration(module) do
    Runner.run(
      Repo,
      [],
      :os.system_time(:microsecond),
      module,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )
  end

  defp count(table) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}")
    count
  end
end
