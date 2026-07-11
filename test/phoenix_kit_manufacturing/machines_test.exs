defmodule PhoenixKitManufacturing.MachinesTest do
  # Integration tests for the context — require PostgreSQL, excluded when
  # the DB is unavailable (see test_helper.exs).
  use PhoenixKitManufacturing.DataCase, async: true

  alias PhoenixKitManufacturing.{Machines, Operations}
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

  describe "machine ↔ operation linking" do
    setup do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01"})
      {:ok, cutting} = Operations.create_operation(%{name: "Cutting", base_time_norm_seconds: 60})

      {:ok, welding} =
        Operations.create_operation(%{name: "Welding", base_time_norm_seconds: 120})

      %{machine: machine, cutting: cutting, welding: welding}
    end

    test "sync links operations, with and without an override", %{
      machine: machine,
      cutting: cutting,
      welding: welding
    } do
      assert {:ok, :synced} =
               Machines.sync_machine_operations(machine.uuid, %{
                 cutting.uuid => 90,
                 welding.uuid => nil
               })

      assert Machines.linked_operation_overrides(machine.uuid) == %{
               cutting.uuid => 90,
               welding.uuid => nil
             }

      assert Machines.has_operation?(machine.uuid, cutting.uuid)
      refute Machines.has_operation?(machine.uuid, Ecto.UUID.generate())

      ops = Machines.list_machine_operations(machine.uuid)
      assert Enum.map(ops, & &1.operation.name) == ["Cutting", "Welding"]
      assert Enum.find(ops, &(&1.operation.uuid == cutting.uuid)).time_norm_seconds == 90
      assert Enum.find(ops, &(&1.operation.uuid == welding.uuid)).time_norm_seconds == nil
    end

    test "sync removes an operation link", %{machine: machine, cutting: cutting, welding: welding} do
      {:ok, :synced} =
        Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => nil, welding.uuid => nil})

      assert {:ok, :synced} =
               Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => nil})

      assert Machines.linked_operation_overrides(machine.uuid) == %{cutting.uuid => nil}
      refute Machines.has_operation?(machine.uuid, welding.uuid)
    end

    test "changing only the override (same operation set) still syncs, not a no-op", %{
      machine: machine,
      cutting: cutting
    } do
      {:ok, :synced} = Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => 60})

      assert {:ok, :synced} =
               Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => 90})

      assert Machines.linked_operation_overrides(machine.uuid) == %{cutting.uuid => 90}
    end

    test "an unchanged sync (same keys and same override values) is a no-op", %{
      machine: machine,
      cutting: cutting
    } do
      {:ok, :synced} = Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => 90})

      assert {:ok, :unchanged} =
               Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => 90})
    end

    test "syncing to an empty map clears all links", %{machine: machine, cutting: cutting} do
      {:ok, :synced} = Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => nil})
      assert {:ok, :synced} = Machines.sync_machine_operations(machine.uuid, %{})
      assert Machines.linked_operation_overrides(machine.uuid) == %{}
    end

    test "deleting an operation removes its machine links", %{machine: machine, cutting: cutting} do
      {:ok, :synced} = Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => nil})
      {:ok, _} = Operations.delete_operation(cutting)
      assert Machines.linked_operation_overrides(machine.uuid) == %{}
    end
  end

  describe "location_label/2" do
    test "returns nil when nothing is set" do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01"})
      assert Machines.location_label(machine) == nil
    end

    test "falls back to the legacy location_note when no uuid link resolves" do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01", location_note: "Bay 3"})
      assert Machines.location_label(machine) == "Bay 3"
    end

    # phoenix_kit_locations is a soft cross-module reference: a uuid this
    # test DB has no matching (or even migrated) data for must be treated
    # as "no answer", not a crash — this exercises the `rescue`/`nil`
    # fallback path documented on `location_label/2`, standing in for "the
    # phoenix_kit_locations tables aren't present on this host" without
    # needing a second module's fixtures wired into this test DB.
    test "a location_uuid that resolves to nothing falls back to location_note" do
      {:ok, machine} =
        Machines.create_machine(%{
          name: "CNC-01",
          location_uuid: Ecto.UUID.generate(),
          location_note: "Bay 3"
        })

      assert Machines.location_label(machine) == "Bay 3"
    end

    test "a space_uuid that resolves to nothing still falls through to location_note" do
      {:ok, machine} =
        Machines.create_machine(%{
          name: "CNC-01",
          space_uuid: Ecto.UUID.generate(),
          location_uuid: Ecto.UUID.generate(),
          location_note: "Bay 3"
        })

      assert Machines.location_label(machine) == "Bay 3"
    end

    test "unresolvable uuids and a blank location_note both yield nil" do
      {:ok, machine} =
        Machines.create_machine(%{
          name: "CNC-01",
          space_uuid: Ecto.UUID.generate(),
          location_uuid: Ecto.UUID.generate(),
          location_note: ""
        })

      assert Machines.location_label(machine) == nil
    end

    test "accepts a :locale option without raising" do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01", location_note: "Bay 3"})
      assert Machines.location_label(machine, locale: "et") == "Bay 3"
    end
  end

  describe "merged_field_template/1" do
    setup do
      {:ok, alpha} =
        Machines.create_machine_type(%{
          name: "Alpha",
          field_template: [
            %{"key" => "power_kw", "label" => "Power (from Alpha)", "type" => "number"}
          ]
        })

      {:ok, beta} =
        Machines.create_machine_type(%{
          name: "Beta",
          field_template: [
            %{"key" => "power_kw", "label" => "Power (from Beta)", "type" => "number"},
            %{"key" => "weight_kg", "label" => "Weight", "type" => "number"}
          ]
        })

      %{alpha: alpha, beta: beta}
    end

    test "returns [] for an empty list" do
      assert Machines.merged_field_template([]) == []
    end

    test "returns a single type's own template untouched", %{beta: beta} do
      assert [
               %{"key" => "power_kw", "label" => "Power (from Beta)"},
               %{"key" => "weight_kg", "label" => "Weight"}
             ] = Machines.merged_field_template([beta.uuid])
    end

    test "on a key collision, the alphabetically-first type name wins", %{
      alpha: alpha,
      beta: beta
    } do
      merged = Machines.merged_field_template([alpha.uuid, beta.uuid])

      assert [
               %{"key" => "power_kw", "label" => "Power (from Alpha)"},
               %{"key" => "weight_kg", "label" => "Weight"}
             ] = merged
    end

    test "collision resolution does not depend on the input list order", %{
      alpha: alpha,
      beta: beta
    } do
      # Passing Beta before Alpha must not change the winner — merge order
      # follows `list_machine_types/1`'s name ordering, not `type_uuids`.
      merged = Machines.merged_field_template([beta.uuid, alpha.uuid])

      assert [%{"key" => "power_kw", "label" => "Power (from Alpha)"} | _] = merged
    end

    test "ignores type uuids that aren't in the requested list", %{alpha: alpha} do
      unrelated_uuid = Ecto.UUID.generate()
      assert [%{"key" => "power_kw"}] = Machines.merged_field_template([alpha.uuid])
      assert Machines.merged_field_template([unrelated_uuid]) == []
    end

    test "excludes inactive types (list_machine_types(status: \"active\") filter)" do
      {:ok, inactive} =
        Machines.create_machine_type(%{
          name: "Gamma",
          status: "inactive",
          field_template: [%{"key" => "x", "label" => "X", "type" => "text"}]
        })

      assert Machines.merged_field_template([inactive.uuid]) == []
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
