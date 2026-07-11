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

  alias PhoenixKitManufacturing.Machines

  defp new_path, do: "/en/admin/manufacturing/machines/new"
  defp edit_path(machine), do: "/en/admin/manufacturing/machines/#{machine.uuid}/edit"

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

  describe "dynamic metadata fields" do
    setup do
      {:ok, type} =
        Machines.create_machine_type(%{
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

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, new_path())

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}})

      assert is_binary(render(view))
    end
  end
end
