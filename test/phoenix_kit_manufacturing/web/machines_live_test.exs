defmodule PhoenixKitManufacturing.Web.MachinesLiveTest do
  # Integration tests — require PostgreSQL, excluded when the DB is
  # unavailable (see test_helper.exs).
  use PhoenixKitManufacturing.LiveCase

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitManufacturing.{EntitiesRegistry, Machines, Paths}

  describe "list pages" do
    test "machines list renders the empty state", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")
      assert html =~ "No machines yet."
    end

    test "an existing machine appears in the list", %{conn: conn} do
      {:ok, _m} = Machines.create_machine(%{name: "CNC-01"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")
      assert html =~ "CNC-01"
    end

    test "the repair and mothballed statuses render their labels", %{conn: conn} do
      {:ok, _m1} = Machines.create_machine(%{name: "Press-02", status: "repair"})
      {:ok, _m2} = Machines.create_machine(%{name: "Old Lathe", status: "mothballed"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")

      assert html =~ "Repair"
      assert html =~ "Mothballed"
    end

    test "a machine's location note appears in the Location column", %{conn: conn} do
      {:ok, _m} =
        Machines.create_machine(%{name: "Router-03", location_note: "Shop Floor A"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")

      assert html =~ "Shop Floor A"
    end

    test "a machine's type name appears as a badge in the Types column", %{conn: conn} do
      start_supervised!(EntitiesRegistry)
      type = create_machine_type!(%{name: "Laser"})
      {:ok, machine} = Machines.create_machine(%{name: "Laser-01"})
      {:ok, _} = Machines.sync_machine_types(machine.uuid, [type.uuid])

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, "/en/admin/manufacturing/machines")

      assert html =~ "Laser-01"
      assert html =~ "Laser"
    end
  end

  describe "global search" do
    test "search by machine name narrows the list", %{conn: conn} do
      {:ok, _m1} = Machines.create_machine(%{name: "CNC Mill"})
      {:ok, _m2} = Machines.create_machine(%{name: "Laser Cutter"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines")

      html = render_change(view, "search", %{"search" => "laser"})

      assert html =~ "Laser Cutter"
      refute html =~ "CNC Mill"
    end

    test "empty search returns all machines", %{conn: conn} do
      {:ok, _m1} = Machines.create_machine(%{name: "CNC Mill"})
      {:ok, _m2} = Machines.create_machine(%{name: "Laser Cutter"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines")

      html = render_change(view, "search", %{"search" => ""})

      assert html =~ "CNC Mill"
      assert html =~ "Laser Cutter"
    end
  end

  describe "sort" do
    test "flipping sort direction reverses the list order", %{conn: conn} do
      {:ok, _} = Machines.create_machine(%{name: "Alpha"})
      {:ok, _} = Machines.create_machine(%{name: "Zeta"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html_asc} = live(conn, "/en/admin/manufacturing/machines")

      # Default is ascending by name — Alpha before Zeta
      asc_pos_alpha = :binary.match(html_asc, "Alpha") |> elem(0)
      asc_pos_zeta = :binary.match(html_asc, "Zeta") |> elem(0)
      assert asc_pos_alpha < asc_pos_zeta

      html_desc = render_click(view, "flip_sort_dir", %{})

      desc_pos_alpha = :binary.match(html_desc, "Alpha") |> elem(0)
      desc_pos_zeta = :binary.match(html_desc, "Zeta") |> elem(0)
      assert desc_pos_zeta < desc_pos_alpha
    end
  end

  describe "machine form" do
    test "creating a machine redirects to the list and persists it", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines/new")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("form", machine: %{name: "New Mill", status: "active"})
               |> render_submit()

      assert to =~ "manufacturing/machines"
      assert [%{name: "New Mill"}] = Machines.list_machines()
    end

    test "an invalid submit re-renders the form with an error", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines/new")

      html =
        view
        |> form("form", machine: %{name: "", status: "active"})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert Machines.count_machines() == 0
    end
  end

  describe "delete flow" do
    test "deleting a machine removes it from the list", %{conn: conn} do
      {:ok, machine} = Machines.create_machine(%{name: "To Delete"})
      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines")

      view
      |> element(~s{button[phx-value-uuid="#{machine.uuid}"][phx-value-type="machine"]})
      |> render_click()

      html = render_click(view, "delete_machine", %{})
      assert html =~ "No machines yet."
      assert Machines.count_machines() == 0
    end
  end

  # `machine_type`/`operation`/`defect_reason` CRUD moved to the generic
  # entities admin UI as of the entities migration (see `MachinesLive`
  # moduledoc) — visiting any of these three subtab routes now redirects
  # straight there instead of rendering a list. The redirect happens on
  # the very first `handle_params/3` call, before any page ever renders,
  # so `live/2` itself returns the `:live_redirect` error tuple rather
  # than `{:ok, view, html}` — same shape as
  # `MachineFormLiveTest`'s "a non-existent machine's tab route..." test.
  # `defect_reasons` is the most recently added of the three subtabs, so
  # it gets its own explicit assertion rather than relying on "types
  # covers the pattern, the others are analogous".
  describe "entities redirects" do
    test "the types subtab redirects to the machine_type entities page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/manufacturing/machines/types")

      assert to == Paths.types()
    end

    test "the operations subtab redirects to the operation entities page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/manufacturing/machines/operations")

      assert to == Paths.operations()
    end

    test "the defect reasons subtab redirects to the defect_reason entities page", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/manufacturing/machines/defect-reasons")

      assert to == Paths.defect_reasons()
    end
  end

  # Web.ColumnManagement's event handlers (add_column, toggle_filter,
  # update_table_columns, set_filter_value, clear_all_filters) have no
  # dedicated test file of their own — covered here end-to-end through
  # MachinesLive, the only current consumer.
  describe "column customization and filters" do
    test "filtering by status narrows the list to matching machines", %{conn: conn} do
      {:ok, _} = Machines.create_machine(%{name: "Healthy Mill", status: "active"})
      {:ok, _} = Machines.create_machine(%{name: "Broken Press", status: "repair"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines")

      # "status" is a default column, so toggle_filter works without an
      # add_column step first.
      render_click(view, "show_column_modal", %{})
      render_click(view, "toggle_filter", %{"column_id" => "status"})
      render_submit(view, "update_table_columns", %{})

      html =
        render_change(view, "set_filter_value", %{"column_id" => "status", "value" => "repair"})

      assert html =~ "Broken Press"
      refute html =~ "Healthy Mill"
    end

    test "clear_all_filters restores the full list", %{conn: conn} do
      {:ok, _} = Machines.create_machine(%{name: "Healthy Mill", status: "active"})
      {:ok, _} = Machines.create_machine(%{name: "Broken Press", status: "repair"})

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, "/en/admin/manufacturing/machines")

      render_click(view, "show_column_modal", %{})
      render_click(view, "toggle_filter", %{"column_id" => "status"})
      render_submit(view, "update_table_columns", %{})
      render_change(view, "set_filter_value", %{"column_id" => "status", "value" => "repair"})

      html = render_click(view, "clear_all_filters", %{})

      assert html =~ "Broken Press"
      assert html =~ "Healthy Mill"
    end

    test "adding a column via the modal persists across a reload for the same user", %{
      conn: conn
    } do
      scope = fake_scope()
      {:ok, _} = Machines.create_machine(%{name: "CNC-01", manufacturer: "Haas"})

      conn1 = put_test_scope(conn, scope)
      {:ok, view, html} = live(conn1, "/en/admin/manufacturing/machines")
      refute html =~ "Manufacturer"

      render_click(view, "show_column_modal", %{})
      render_click(view, "add_column", %{"column_id" => "manufacturer"})

      html =
        render_submit(view, "update_table_columns", %{
          "column_order" => "name,code,status,location,types,manufacturer"
        })

      assert html =~ "Manufacturer"

      conn2 =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_test_scope(scope)

      {:ok, _view2, html2} = live(conn2, "/en/admin/manufacturing/machines")
      assert html2 =~ "Manufacturer"
    end
  end

  ## Helpers

  # `machine_type` CRUD moved to the generic entities admin UI (see
  # `Machines` moduledoc) — tests that need one build it directly against
  # `phoenix_kit_entities`'s own API, same pattern as `MachinesTest`'s and
  # `MachineFormLiveTest`'s identically-named private helpers. Callers
  # must have already started `EntitiesRegistry` (`start_supervised!/1`)
  # — this always ends with a synchronous `reload/0` so `MachinesLive`
  # (which reads type names through the registry, not the DB directly)
  # sees the fixture by the time `live/2` mounts.
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
end
