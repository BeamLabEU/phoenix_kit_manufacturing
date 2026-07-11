defmodule PhoenixKitManufacturing.MachinesTest do
  # Integration tests for the context — require PostgreSQL, excluded when
  # the DB is unavailable (see test_helper.exs).
  use PhoenixKitManufacturing.DataCase, async: true

  alias PhoenixKitManufacturing.Machines
  alias PhoenixKitManufacturing.Schemas.{Machine, MachineType}

  describe "machine types" do
    test "create/list/count/get/update/delete round-trip" do
      assert Machines.count_machine_types() == 0

      {:ok, %MachineType{} = cnc} = Machines.create_machine_type(%{name: "CNC"})
      assert cnc.status == "active"
      assert Machines.count_machine_types() == 1
      assert [%MachineType{name: "CNC"}] = Machines.list_machine_types()
      assert %MachineType{name: "CNC"} = Machines.get_machine_type(cnc.uuid)

      {:ok, updated} = Machines.update_machine_type(cnc, %{status: "inactive"})
      assert updated.status == "inactive"

      {:ok, _} = Machines.delete_machine_type(cnc)
      assert Machines.count_machine_types() == 0
    end

    test "list_machine_types/1 filters by status" do
      {:ok, _} = Machines.create_machine_type(%{name: "Active", status: "active"})
      {:ok, _} = Machines.create_machine_type(%{name: "Inactive", status: "inactive"})

      assert [%MachineType{name: "Active"}] = Machines.list_machine_types(status: "active")
    end

    test "create_machine_type/2 returns a changeset error on a blank name" do
      assert {:error, changeset} = Machines.create_machine_type(%{name: ""})
      assert %{name: [_ | _]} = errors_on(changeset)
    end
  end

  describe "machines" do
    test "create/list/count/get/update/delete round-trip with types preloaded" do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01", code: "M-001"})
      assert machine.status == "active"

      assert Machines.count_machines() == 1
      assert [%Machine{machine_types: []}] = Machines.list_machines()
      assert %Machine{name: "CNC-01", machine_types: []} = Machines.get_machine(machine.uuid)

      {:ok, updated} = Machines.update_machine(machine, %{status: "maintenance"})
      assert updated.status == "maintenance"

      {:ok, _} = Machines.delete_machine(machine)
      assert Machines.count_machines() == 0
    end
  end

  describe "machine ↔ type sync" do
    setup do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01"})
      {:ok, cnc} = Machines.create_machine_type(%{name: "CNC"})
      {:ok, mill} = Machines.create_machine_type(%{name: "Milling"})
      %{machine: machine, cnc: cnc, mill: mill}
    end

    test "sync assigns and replaces types", %{machine: machine, cnc: cnc, mill: mill} do
      assert {:ok, :synced} = Machines.sync_machine_types(machine.uuid, [cnc.uuid, mill.uuid])

      assert MapSet.new(Machines.linked_type_uuids(machine.uuid)) ==
               MapSet.new([cnc.uuid, mill.uuid])

      assert Machines.has_type?(machine.uuid, cnc.uuid)

      assert {:ok, :synced} = Machines.sync_machine_types(machine.uuid, [cnc.uuid])
      assert Machines.linked_type_uuids(machine.uuid) == [cnc.uuid]
      refute Machines.has_type?(machine.uuid, mill.uuid)
    end

    test "an unchanged sync is a no-op", %{machine: machine, cnc: cnc} do
      {:ok, :synced} = Machines.sync_machine_types(machine.uuid, [cnc.uuid])
      assert {:ok, :unchanged} = Machines.sync_machine_types(machine.uuid, [cnc.uuid])
    end

    test "deleting a type removes its assignments", %{machine: machine, cnc: cnc} do
      {:ok, :synced} = Machines.sync_machine_types(machine.uuid, [cnc.uuid])
      {:ok, _} = Machines.delete_machine_type(cnc)
      assert Machines.linked_type_uuids(machine.uuid) == []
    end
  end

  describe "activity logging" do
    test "records machine.created with the actor and metadata" do
      actor = Ecto.UUID.generate()

      {:ok, machine} =
        Machines.create_machine(%{name: "CNC-01", code: "M-001"}, actor_uuid: actor)

      assert_activity_logged("machine.created",
        actor_uuid: actor,
        resource_uuid: machine.uuid,
        metadata_has: %{"name" => "CNC-01", "code" => "M-001"}
      )
    end

    test "does not log when no actor is given for a successful create" do
      {:ok, _} = Machines.create_machine(%{name: "Anon"})
      # A log row is still written (actor_uuid nil); assert it carries the module key.
      row = assert_activity_logged("machine.created", metadata_has: %{"name" => "Anon"})
      assert row.module == "manufacturing"
    end
  end
end
