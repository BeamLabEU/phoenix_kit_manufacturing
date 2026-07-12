defmodule PhoenixKitManufacturing.Web.MachineFormLiveTest do
  # Integration tests — require PostgreSQL, excluded when the DB is
  # unavailable (see test_helper.exs).
  #
  # `phoenix_kit_locations` itself is not migrated into this test DB (only
  # core + this module's own tables are, see test_helper.exs), so these
  # tests never resolve a *real* Location/Space — that's covered by
  # `Machines.location_label/2`'s own rescue-path tests in
  # `machines_test.exs`. What's covered here is this LiveView's own wiring:
  # the Location card's visibility/toggle, the `place_picker_select`
  # message handling, and the new passport/dynamic-metadata fields.
  use PhoenixKitManufacturing.LiveCase

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitManufacturing.{EntitiesRegistry, Machines, Paths}

  defp new_path, do: "/en/admin/manufacturing/machines/new"
  defp edit_path(machine), do: "/en/admin/manufacturing/machines/#{machine.uuid}/edit"
  defp operations_path(machine), do: "/en/admin/manufacturing/machines/#{machine.uuid}/operations"
  defp files_path(machine), do: "/en/admin/manufacturing/machines/#{machine.uuid}/files"
  defp comments_path(machine), do: "/en/admin/manufacturing/machines/#{machine.uuid}/comments"

  describe "statuses" do
    test "the status select offers the new repair/mothballed options", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, new_path())

      assert html =~ "Repair"
      assert html =~ "Mothballed"
    end

    test "a machine can be saved with the new repair status", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form", machine: %{name: "Press-1", status: "repair"})
               |> render_submit()

      assert [%{status: "repair"}] = Machines.list_machines()
    end
  end

  describe "passport fields" do
    test "new passport fields round-trip on save, including the to_next_on auto-compute", %{
      conn: conn
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form",
                 machine: %{
                   name: "CNC-07",
                   status: "active",
                   model: "X200",
                   manufacture_year: "2020",
                   commissioned_on: "2020-05-01",
                   to_last_on: "2026-01-01",
                   to_interval_days: "90",
                   notes: "Internal note"
                 }
               )
               |> render_submit()

      assert [machine] = Machines.list_machines()
      assert machine.model == "X200"
      assert machine.manufacture_year == 2020
      assert machine.commissioned_on == ~D[2020-05-01]
      assert machine.to_last_on == ~D[2026-01-01]
      assert machine.to_interval_days == 90
      assert machine.to_next_on == Date.add(~D[2026-01-01], 90)
      assert machine.notes == "Internal note"
    end
  end

  describe "location_note (legacy) visibility" do
    test "never rendered for a new machine", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, new_path())
      refute html =~ "Location (legacy note)"
    end

    test "hidden on edit when blank", %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-08"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, edit_path(machine))
      refute html =~ "Location (legacy note)"
    end

    test "shown on edit when set", %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-09", location_note: "Bay 3"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, edit_path(machine))
      assert html =~ "Location (legacy note)"
    end
  end

  describe "Location card" do
    test "defaults to expanded with 'Not set' for a brand new machine", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, new_path())

      assert html =~ "Not set"
      assert has_element?(view, "#machine-place-picker")
    end

    test "defaults to collapsed once a location is already on file", %{conn: conn} do
      {:ok, machine} =
        Machines.create_machine(%{name: "CNC-10", location_uuid: Ecto.UUID.generate()})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      refute has_element?(view, "#machine-place-picker")
    end

    test "toggle_place_picker flips visibility", %{conn: conn} do
      {:ok, machine} =
        Machines.create_machine(%{name: "CNC-11", location_uuid: Ecto.UUID.generate()})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      refute has_element?(view, "#machine-place-picker")
      render_click(view, "toggle_place_picker", %{})
      assert has_element?(view, "#machine-place-picker")
    end

    test "a place_picker_select message updates assigns, collapses the picker, and is persisted on save",
         %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-12"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      assert has_element?(view, "#machine-place-picker")

      picked_location = Ecto.UUID.generate()
      picked_space = Ecto.UUID.generate()

      send(
        view.pid,
        {:place_picker_select, "machine-place-picker",
         %{location_uuid: picked_location, space_uuid: picked_space}}
      )

      _html = render(view)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.location_uuid == picked_location
      assert assigns.space_uuid == picked_space
      refute assigns.show_place_picker
      refute has_element?(view, "#machine-place-picker")

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form", machine: %{name: "CNC-12", status: "active"})
               |> render_submit()

      updated = Machines.get_machine(machine.uuid)
      assert updated.location_uuid == picked_location
      assert updated.space_uuid == picked_space
    end
  end

  describe "Machine card tabs" do
    test "a :new machine renders no tab bar (single-page General only)", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, new_path())

      refute html =~ "tabs-border"
    end

    test "an :edit machine renders a tab bar with General active by default", %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-50"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, edit_path(machine))

      assert html =~ "tabs-border"
      assert has_element?(view, "a.tab-active", "General")
      assert has_element?(view, "a", "Files")
    end

    test "the Files tab patches to the Files route and renders the files card", %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-51"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      html = render_patch(view, files_path(machine))

      assert html =~ "Featured Image"
      assert html =~ "Attached Files"
      assert has_element?(view, "a.tab-active", "Files")
      refute has_element?(view, "a.tab-active", "General")
    end

    test "the Comments tab link is absent and its route doesn't crash when comments are unavailable",
         %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-52"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      refute has_element?(view, "a", "Comments")

      html = render_patch(view, comments_path(machine))
      assert is_binary(html)
    end

    test "when comments are enabled, the Comments tab link is shown and deep-linking to it renders as active",
         %{conn: conn} do
      {:ok, _} = PhoenixKitComments.enable_system()
      on_exit(fn -> PhoenixKitComments.disable_system() end)

      {:ok, machine} = Machines.create_machine(%{name: "CNC-52b"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      assert has_element?(view, "a", "Comments")

      render_patch(view, comments_path(machine))

      assert has_element?(view, "a.tab-active", "Comments")
      refute has_element?(view, "a.tab-active", "General")
    end

    test "a non-existent machine's tab route flashes and redirects to the machines list", %{
      conn: conn
    } do
      conn = put_test_scope(conn, fake_scope())
      bad_uuid = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/manufacturing/machines/#{bad_uuid}/operations")

      assert to =~ "machines"
    end

    test "switching tabs preserves a pending (unsaved) type toggle", %{conn: conn} do
      start_supervised!(EntitiesRegistry)
      type = create_machine_type!(%{name: "Lathe"})
      {:ok, machine} = Machines.create_machine(%{name: "CNC-53"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      render_click(view, "toggle_type", %{"uuid" => type.uuid})
      assert has_element?(view, "label.badge-primary", "Lathe")

      render_patch(view, files_path(machine))
      render_patch(view, edit_path(machine))

      assert has_element?(view, "label.badge-primary", "Lathe")
    end
  end

  describe "Machine Types badges" do
    test "each type badge carries a link to its field-template editor", %{conn: conn} do
      start_supervised!(EntitiesRegistry)
      type = create_machine_type!(%{name: "Lathe"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      assert has_element?(view, "a[href='#{Paths.machine_type_template(type.uuid)}']")
    end
  end

  describe "dynamic metadata fields" do
    setup do
      start_supervised!(EntitiesRegistry)

      type =
        create_machine_type!(%{
          name: "CNC",
          field_template: [
            %{"key" => "power_kw", "label" => "Power", "type" => "number", "unit" => "kW"},
            %{"key" => "notes_field", "label" => "Spec notes", "type" => "text"},
            %{"key" => "calibrated_on", "label" => "Calibrated on", "type" => "date"},
            %{"key" => "networked", "label" => "Networked", "type" => "boolean"},
            %{
              "key" => "voltage",
              "label" => "Voltage",
              "type" => "select",
              "options" => ["110V", "220V"]
            }
          ]
        })

      %{type: type}
    end

    test "linking a type renders its dynamic fields; unlinking removes them", %{
      conn: conn,
      type: type
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, new_path())

      refute html =~ "machine[metadata][power_kw]"

      html = render_click(view, "toggle_type", %{"uuid" => type.uuid})
      assert html =~ "machine[metadata][power_kw]"
      assert html =~ "machine[metadata][notes_field]"
      assert html =~ "machine[metadata][calibrated_on]"
      assert html =~ "machine[metadata][networked]"
      assert html =~ "machine[metadata][voltage]"

      html = render_click(view, "toggle_type", %{"uuid" => type.uuid})
      refute html =~ "machine[metadata][power_kw]"
    end

    test "saving coerces the boolean field and stores the rest as submitted strings", %{
      conn: conn,
      type: type
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      render_click(view, "toggle_type", %{"uuid" => type.uuid})

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form",
                 machine: %{
                   name: "CNC-20",
                   status: "active",
                   metadata: %{
                     "power_kw" => "5.5",
                     "notes_field" => "Freeform",
                     "calibrated_on" => "2026-01-01",
                     "networked" => "true",
                     "voltage" => "220V"
                   }
                 }
               )
               |> render_submit()

      assert [machine] = Machines.list_machines()

      assert machine.metadata == %{
               "power_kw" => "5.5",
               "notes_field" => "Freeform",
               "calibrated_on" => "2026-01-01",
               "networked" => true,
               "voltage" => "220V"
             }
    end

    test "an untouched boolean field defaults to unchecked and is coerced to false", %{
      conn: conn,
      type: type
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      render_click(view, "toggle_type", %{"uuid" => type.uuid})

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form",
                 machine: %{name: "CNC-21", status: "active", metadata: %{"power_kw" => "1"}}
               )
               |> render_submit()

      assert [machine] = Machines.list_machines()
      assert machine.metadata["networked"] == false
    end
  end

  describe "Operations tab" do
    setup do
      start_supervised!(EntitiesRegistry)
      :ok
    end

    test "never appears on a :new machine (single-page General only)", %{conn: conn} do
      _operation = create_operation!(%{name: "Cutting", unit: "pcs", base_time_norm_seconds: 120})

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, new_path())

      refute html =~ "Toggle the operations this machine performs"
    end

    test "the tab link is hidden on an edit machine when there are no published operations", %{
      conn: conn
    } do
      {:ok, machine} = Machines.create_machine(%{name: "CNC-29"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      refute has_element?(view, "a", "Operations")
    end
  end

  describe "Operations tab with a published operation" do
    setup do
      start_supervised!(EntitiesRegistry)

      operation =
        create_operation!(%{
          name: "Cutting",
          unit: "pcs",
          base_time_norm_seconds: 120
        })

      {:ok, machine} = Machines.create_machine(%{name: "CNC-Op"})

      %{operation: operation, machine: machine}
    end

    test "the tab link is shown", %{conn: conn, machine: machine} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))

      assert has_element?(view, "a", "Operations")
    end

    test "renders every published operation, unchecked, with no override input", %{
      conn: conn,
      machine: machine,
      operation: operation
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))
      html = render_patch(view, operations_path(machine))

      assert html =~ "Cutting"
      assert has_element?(view, "a.tab-active", "Operations")
      refute has_element?(view, "input[name='operation_override_#{operation.uuid}']")
    end

    test "toggle_operation shows the override input; toggling again hides it", %{
      conn: conn,
      machine: machine,
      operation: operation
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))
      render_patch(view, operations_path(machine))

      render_click(view, "toggle_operation", %{"uuid" => operation.uuid})
      assert has_element?(view, "input[name='operation_override_#{operation.uuid}']")

      render_click(view, "toggle_operation", %{"uuid" => operation.uuid})
      refute has_element?(view, "input[name='operation_override_#{operation.uuid}']")
    end

    test "linking an operation with no override persists a nil override on save", %{
      conn: conn,
      machine: machine,
      operation: operation
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))
      render_patch(view, operations_path(machine))

      render_click(view, "toggle_operation", %{"uuid" => operation.uuid})

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form", machine: %{name: machine.name, status: "active"})
               |> render_submit()

      assert Machines.linked_operation_overrides(machine.uuid) == %{operation.uuid => nil}
    end

    test "set_operation_override persists the override on save", %{
      conn: conn,
      machine: machine,
      operation: operation
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))
      render_patch(view, operations_path(machine))

      render_click(view, "toggle_operation", %{"uuid" => operation.uuid})
      render_click(view, "set_operation_override", %{"uuid" => operation.uuid, "value" => "45"})

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form", machine: %{name: machine.name, status: "active"})
               |> render_submit()

      assert Machines.linked_operation_overrides(machine.uuid) == %{operation.uuid => 45}
    end

    test "a blank override value clears back to nil (use the operation's base norm)", %{
      conn: conn,
      machine: machine,
      operation: operation
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))
      render_patch(view, operations_path(machine))

      render_click(view, "toggle_operation", %{"uuid" => operation.uuid})
      render_click(view, "set_operation_override", %{"uuid" => operation.uuid, "value" => "45"})
      render_click(view, "set_operation_override", %{"uuid" => operation.uuid, "value" => ""})

      assert {:error, {:live_redirect, _}} =
               view
               |> form("form", machine: %{name: machine.name, status: "active"})
               |> render_submit()

      assert Machines.linked_operation_overrides(machine.uuid) == %{operation.uuid => nil}
    end

    test "a stray set_operation_override for an unlinked operation is a no-op", %{
      conn: conn,
      machine: machine,
      operation: operation
    } do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))
      render_patch(view, operations_path(machine))

      render_click(view, "set_operation_override", %{"uuid" => operation.uuid, "value" => "45"})

      assigns = :sys.get_state(view.pid).socket.assigns
      refute Map.has_key?(assigns.operation_overrides, operation.uuid)
    end

    test "editing an existing machine preloads its linked operations and overrides", %{
      conn: conn,
      machine: machine,
      operation: operation
    } do
      {:ok, _} = Machines.sync_machine_operations(machine.uuid, %{operation.uuid => 60})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, edit_path(machine))
      render_patch(view, operations_path(machine))

      assert has_element?(view, "input[name='operation_override_#{operation.uuid}'][value='60']")
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}})

      assert is_binary(render(view))
    end
  end

  ## Helpers

  # `machine_type`/`operation` CRUD moved to the generic entities admin UI
  # (see `Machines` moduledoc) — tests that need a record build it directly
  # against `phoenix_kit_entities`'s own API, same pattern as
  # `MachinesTest`'s identically-named private helpers. Callers must have
  # already started `EntitiesRegistry` (`start_supervised!/1`) — this always
  # ends with a synchronous `reload/0` so `MachineFormLive`'s pickers (which
  # read through the registry, not the DB directly) see the fixture by the
  # time `live/2` mounts.
  defp create_machine_type!(attrs) do
    entity =
      Entities.get_entity_by_name("machine_type") ||
        raise "machine_type entity not seeded — check Migrations.Machines V5"

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

  # Same rationale as `create_machine_type!/1`. `unit`/`base_time_norm_seconds`
  # are non-translatable custom fields, so they land unprefixed in the
  # primary-language data block (see `EntitiesRegistry`'s "Record shape"
  # moduledoc).
  defp create_operation!(attrs) do
    entity =
      Entities.get_entity_by_name("operation") ||
        raise "operation entity not seeded — check Migrations.Machines V5"

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
