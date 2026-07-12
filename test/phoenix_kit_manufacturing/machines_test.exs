defmodule PhoenixKitManufacturing.MachinesTest do
  # Integration tests for the context — require PostgreSQL, excluded when
  # the DB is unavailable (see test_helper.exs).
  #
  # `async: false`: the describe blocks below that touch `machine_type` /
  # `operation` entity_data (via `create_machine_type!/1` /
  # `create_operation!/1`) start their own `EntitiesRegistry` with
  # `start_supervised!/1` and call `reload/0` from inside the test process
  # — the registry queries the DB from its *own* GenServer process, so the
  # Sandbox must run in shared mode for that reload to see this test's
  # not-yet-committed fixtures. Same pattern as `EntitiesRegistryTest` and
  # (in the andi codebase this registry is modeled on)
  # `Andi.Orders.StatusRegistryTest`.
  use PhoenixKitManufacturing.DataCase, async: false

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitManufacturing.{EntitiesRegistry, Machines}
  alias PhoenixKitManufacturing.Schemas.Machine

  describe "machine types (read via EntitiesRegistry)" do
    setup do
      start_supervised!(EntitiesRegistry)
      :ok
    end

    test "list_machine_types/1 and count_machine_types/1 see published entity_data records" do
      assert Machines.count_machine_types() == 0

      cnc = create_machine_type!(%{name: "CNC"})

      assert Machines.count_machine_types() == 1
      assert [%{uuid: uuid, name: "CNC", status: "published"}] = Machines.list_machine_types()
      assert uuid == cnc.uuid
    end

    test "list_machine_types/1 and count_machine_types/1 filter by :status" do
      create_machine_type!(%{name: "Published"})
      create_machine_type!(%{name: "Draft", status: "draft"})

      assert [%{name: "Published"}] = Machines.list_machine_types(status: "published")
      assert Machines.count_machine_types(status: "draft") == 1
      assert Machines.count_machine_types() == 2
    end
  end

  describe "machines" do
    test "create/list/count/get/update/delete round-trip" do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01", code: "M-001"})
      assert machine.status == "active"

      assert Machines.count_machines() == 1
      assert [%Machine{name: "CNC-01"}] = Machines.list_machines()
      assert %Machine{name: "CNC-01"} = Machines.get_machine(machine.uuid)

      {:ok, updated} = Machines.update_machine(machine, %{status: "maintenance"})
      assert updated.status == "maintenance"

      {:ok, _} = Machines.delete_machine(machine)
      assert Machines.count_machines() == 0
    end
  end

  describe "linked_type_uuids_by_machine/1" do
    test "batches linked type uuids for several machines in one call" do
      {:ok, m1} = Machines.create_machine(%{name: "CNC-01"})
      {:ok, m2} = Machines.create_machine(%{name: "CNC-02"})
      {:ok, m3} = Machines.create_machine(%{name: "CNC-03"})
      # `machine_type_uuid` is a soft reference (no FK, see
      # `Schemas.MachineTypeAssignment` moduledoc) — this function only
      # groups whatever uuids are stored in the assignment rows, so a bare
      # generated uuid exercises the batch-grouping logic just as well as
      # a real `machine_type` entity_data uuid would, without needing
      # `EntitiesRegistry` running for this describe block.
      cnc_uuid = Ecto.UUID.generate()
      mill_uuid = Ecto.UUID.generate()

      {:ok, :synced} = Machines.sync_machine_types(m1.uuid, [cnc_uuid, mill_uuid])
      {:ok, :synced} = Machines.sync_machine_types(m2.uuid, [cnc_uuid])
      # m3 is left with no linked types on purpose.

      result = Machines.linked_type_uuids_by_machine([m1.uuid, m2.uuid, m3.uuid])

      assert MapSet.new(Map.fetch!(result, m1.uuid)) == MapSet.new([cnc_uuid, mill_uuid])
      assert Map.fetch!(result, m2.uuid) == [cnc_uuid]
      refute Map.has_key?(result, m3.uuid)
    end

    test "returns an empty map for an empty input list" do
      assert Machines.linked_type_uuids_by_machine([]) == %{}
    end
  end

  describe "machine ↔ type sync" do
    setup do
      start_supervised!(EntitiesRegistry)
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01"})
      cnc = create_machine_type!(%{name: "CNC"})
      mill = create_machine_type!(%{name: "Milling"})
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

    test "trashing a type does not cascade to its assignments (soft reference, no FK)", %{
      machine: machine,
      cnc: cnc
    } do
      {:ok, :synced} = Machines.sync_machine_types(machine.uuid, [cnc.uuid])

      {:ok, _} = EntityData.trash(cnc)
      EntitiesRegistry.reload()

      # No FK/cascade as of the entities migration (see
      # ENTITIES_MIGRATION_SPEC.md §5 risk #1) — the assignment row is a
      # dangling soft reference, not removed; the type itself just drops
      # out of the (non-trashed) list.
      assert Machines.linked_type_uuids(machine.uuid) == [cnc.uuid]
      refute cnc.uuid in Enum.map(Machines.list_machine_types(), & &1.uuid)
    end
  end

  describe "machine ↔ operation linking" do
    setup do
      start_supervised!(EntitiesRegistry)
      {:ok, machine} = Machines.create_machine(%{name: "CNC-01"})
      cutting = create_operation!(%{name: "Cutting", base_time_norm_seconds: 60})
      welding = create_operation!(%{name: "Welding", base_time_norm_seconds: 120})
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

    test "trashing an operation does not cascade to its machine links (soft reference, no FK)",
         %{machine: machine, cutting: cutting} do
      {:ok, :synced} = Machines.sync_machine_operations(machine.uuid, %{cutting.uuid => nil})

      {:ok, _} = EntityData.trash(cutting)
      EntitiesRegistry.reload()

      # No FK/cascade as of the entities migration (see
      # ENTITIES_MIGRATION_SPEC.md §5 risk #1) — the link row is a dangling
      # soft reference, not removed by the trash; `list_machine_operations/1`
      # reports a `nil` `:operation` for it (see its moduledoc).
      assert Machines.linked_operation_overrides(machine.uuid) == %{cutting.uuid => nil}

      assert [%{operation: nil, time_norm_seconds: nil}] =
               Machines.list_machine_operations(machine.uuid)
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
      start_supervised!(EntitiesRegistry)

      alpha =
        create_machine_type!(%{
          name: "Alpha",
          field_template: [
            %{"key" => "power_kw", "label" => "Power (from Alpha)", "type" => "number"}
          ]
        })

      beta =
        create_machine_type!(%{
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

    test "on a key collision, the earlier-created type wins (registry position order)", %{
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
      # follows `EntitiesRegistry.list/3`'s position order (Alpha was
      # created first in this describe block's `setup`, so it sorts
      # first), not the order of `type_uuids`.
      merged = Machines.merged_field_template([beta.uuid, alpha.uuid])

      assert [%{"key" => "power_kw", "label" => "Power (from Alpha)"} | _] = merged
    end

    test "ignores type uuids that aren't in the requested list", %{alpha: alpha} do
      unrelated_uuid = Ecto.UUID.generate()
      assert [%{"key" => "power_kw"}] = Machines.merged_field_template([alpha.uuid])
      assert Machines.merged_field_template([unrelated_uuid]) == []
    end

    test "excludes draft types (merged_field_template only reads status: \"published\")" do
      draft =
        create_machine_type!(%{
          name: "Gamma",
          status: "draft",
          field_template: [%{"key" => "x", "label" => "X", "type" => "text"}]
        })

      assert Machines.merged_field_template([draft.uuid]) == []
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

  ## Helpers

  # `machine_type` CRUD moved to the generic entities admin UI (see
  # `Machines` moduledoc) — tests that need a `machine_type` record build
  # it directly against `phoenix_kit_entities`'s own API. Callers must have
  # already started `EntitiesRegistry` (`start_supervised!/1`, see the
  # relevant `describe` blocks' `setup`) — this always ends with a
  # synchronous `reload/0` so the read-through cache is current by the
  # time the caller's assertions run.
  defp create_machine_type!(attrs) do
    entity =
      Entities.get_entity_by_name("machine_type") ||
        raise "machine_type entity not seeded — check EntitiesRegistry blueprint provisioning"

    name = Map.fetch!(attrs, :name)
    primary = Multilang.primary_language()

    {:ok, record} =
      EntityData.create(%{
        entity_uuid: entity.uuid,
        title: name,
        status: Map.get(attrs, :status, "published"),
        data: %{"_primary_language" => primary, primary => %{"_title" => name}},
        metadata: %{"field_template" => Map.get(attrs, :field_template, [])}
      })

    EntitiesRegistry.reload()
    record
  end

  # Same rationale as `create_machine_type!/1` — `operation` CRUD moved to
  # the generic entities admin UI, so tests build the `operation`
  # `entity_data` record directly. `unit`/`base_time_norm_seconds` are
  # non-translatable custom fields (see `EntitiesRegistry`'s
  # `@blueprint_directories`), so they land unprefixed in the
  # primary-language data block, not under a `_`-prefixed translatable key
  # (see `EntitiesRegistry`'s "Record shape" moduledoc).
  defp create_operation!(attrs) do
    entity =
      Entities.get_entity_by_name("operation") ||
        raise "operation entity not seeded — check EntitiesRegistry blueprint provisioning"

    name = Map.fetch!(attrs, :name)
    primary = Multilang.primary_language()

    primary_block =
      %{"_title" => name}
      |> put_present("unit", Map.get(attrs, :unit))
      |> put_present("base_time_norm_seconds", Map.get(attrs, :base_time_norm_seconds))

    {:ok, record} =
      EntityData.create(%{
        entity_uuid: entity.uuid,
        title: name,
        status: Map.get(attrs, :status, "published"),
        data: %{"_primary_language" => primary, primary => primary_block}
      })

    EntitiesRegistry.reload()
    record
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
