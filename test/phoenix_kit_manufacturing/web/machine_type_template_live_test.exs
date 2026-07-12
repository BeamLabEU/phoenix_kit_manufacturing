defmodule PhoenixKitManufacturing.Web.MachineTypeTemplateLiveTest do
  # Integration tests — require PostgreSQL, excluded when the DB is
  # unavailable (see test_helper.exs).
  #
  # Unlike `MachineFormLiveTest`, these never need `EntitiesRegistry`
  # started — this LiveView reads/writes a single `EntityData` record
  # directly (see its moduledoc), it never goes through the ETS cache.
  use PhoenixKitManufacturing.LiveCase

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitManufacturing.Paths

  defp template_path(uuid), do: "/en/admin/manufacturing/machine-types/#{uuid}/template"

  describe "loading" do
    test "renders the machine type's existing field_template rows", %{conn: conn} do
      type =
        create_machine_type!("CNC",
          field_template: [
            %{"key" => "power_kw", "label" => "Power", "type" => "number", "unit" => "kW"}
          ]
        )

      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, template_path(type.uuid))

      assert html =~ "Field Template: CNC"
      assert html =~ "power_kw"
      assert html =~ "Power"
    end

    test "an unknown uuid flashes and redirects to the types list", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())
      bad_uuid = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, template_path(bad_uuid))
      assert to == Paths.types()
    end

    test "a uuid belonging to a different entity is treated as not found", %{conn: conn} do
      operation = create_operation!("Milling")
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, template_path(operation.uuid))
      assert to == Paths.types()
    end
  end

  describe "editing rows" do
    test "adding and saving a row persists it, keeping legacy_uuid intact", %{conn: conn} do
      type =
        create_machine_type!("Lathe", legacy_uuid: "11111111-1111-1111-1111-111111111111")

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, template_path(type.uuid))

      render_click(view, "add_field_row", %{})

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("form",
                 field_template: %{
                   "0" => %{
                     "key" => "power_kw",
                     "label" => "Power",
                     "type" => "number",
                     "unit" => "kW",
                     "required" => "true"
                   }
                 }
               )
               |> render_submit()

      assert to == Paths.types()

      reloaded = EntityData.get!(type.uuid)

      assert reloaded.metadata["field_template"] == [
               %{
                 "key" => "power_kw",
                 "label" => "Power",
                 "type" => "number",
                 "unit" => "kW",
                 "required" => true,
                 "options" => []
               }
             ]

      assert reloaded.metadata["legacy_uuid"] == "11111111-1111-1111-1111-111111111111"
    end

    test "a metadata key written by another process after mount survives save", %{conn: conn} do
      type = create_machine_type!("Mill")

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, template_path(type.uuid))

      # Simulate a concurrent write (e.g. the trash flow setting
      # `trashed_from_status`) landing between this session's mount and its
      # save — `persist/2` must merge onto a fresh read, not the
      # mount-time `entity_data` snapshot, or this key would be clobbered.
      {:ok, _} =
        EntityData.update(type, %{
          metadata: Map.put(type.metadata || %{}, "trashed_from_status", "published")
        })

      render_click(view, "add_field_row", %{})

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("form",
                 field_template: %{
                   "0" => %{"key" => "rpm", "label" => "RPM", "type" => "number"}
                 }
               )
               |> render_submit()

      assert to == Paths.types()

      reloaded = EntityData.get!(type.uuid)
      assert reloaded.metadata["trashed_from_status"] == "published"
      assert [%{"key" => "rpm"}] = reloaded.metadata["field_template"]
    end

    test "removing the only row and saving persists an empty template", %{conn: conn} do
      type =
        create_machine_type!("Press",
          field_template: [%{"key" => "tonnage", "label" => "Tonnage", "type" => "number"}]
        )

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, template_path(type.uuid))
      assert html =~ "tonnage"

      render_click(view, "remove_field_row", %{"index" => "0"})

      assert {:error, {:live_redirect, %{to: to}}} = view |> form("form", %{}) |> render_submit()
      assert to == Paths.types()

      assert EntityData.get!(type.uuid).metadata["field_template"] == []
    end
  end

  describe "validation" do
    test "an invalid key format blocks save and reports the row", %{conn: conn} do
      type = create_machine_type!("Grinder")

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, template_path(type.uuid))

      render_click(view, "add_field_row", %{})

      html =
        view
        |> form("form",
          field_template: %{
            "0" => %{"key" => "Bad Key!", "label" => "Bad", "type" => "text"}
          }
        )
        |> render_submit()

      assert html =~ "Invalid row at index 0"
      assert EntityData.get!(type.uuid).metadata["field_template"] in [nil, []]
    end

    test "a duplicate key across two rows blocks save", %{conn: conn} do
      type = create_machine_type!("Welder")

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, template_path(type.uuid))

      render_click(view, "add_field_row", %{})
      render_click(view, "add_field_row", %{})

      html =
        view
        |> form("form",
          field_template: %{
            "0" => %{"key" => "amps", "label" => "Amps", "type" => "number"},
            "1" => %{"key" => "amps", "label" => "Amps again", "type" => "number"}
          }
        )
        |> render_submit()

      assert html =~ "Duplicate key: amps"
      assert EntityData.get!(type.uuid).metadata["field_template"] in [nil, []]
    end

    test "a select row with no options blocks save", %{conn: conn} do
      type = create_machine_type!("Saw")

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _html} = live(conn, template_path(type.uuid))

      render_click(view, "add_field_row", %{})

      # Switch the row's type to "select" first (a real user flow — the
      # "Options" input is only rendered once `@row["type"] == "select"`,
      # see the LiveView's `field_template_row/1`), then submit it blank.
      view
      |> form("form",
        field_template: %{"0" => %{"key" => "voltage", "label" => "Voltage", "type" => "select"}}
      )
      |> render_change()

      html =
        view
        |> form("form",
          field_template: %{
            "0" => %{
              "key" => "voltage",
              "label" => "Voltage",
              "type" => "select",
              "options" => ""
            }
          }
        )
        |> render_submit()

      assert html =~ "Invalid row at index 0"
      assert EntityData.get!(type.uuid).metadata["field_template"] in [nil, []]
    end
  end

  describe "cancel" do
    test "the Cancel link points at the entities types list", %{conn: conn} do
      type = create_machine_type!("Drill")
      conn = put_test_scope(conn, fake_scope())
      {:ok, _view, html} = live(conn, template_path(type.uuid))

      assert html =~ Paths.types()
    end
  end

  ## Helpers

  # Same rationale/pattern as `MachineFormLiveTest`'s identically-named
  # helper — `machine_type` CRUD lives on the generic entities admin UI, so
  # tests build fixtures directly against `phoenix_kit_entities`'s own API.
  defp create_machine_type!(name, attrs \\ []) do
    entity =
      Entities.get_entity_by_name("machine_type") ||
        raise "machine_type entity not seeded — check EntitiesRegistry blueprint provisioning"

    primary = Multilang.primary_language()

    metadata =
      %{"field_template" => Keyword.get(attrs, :field_template, [])}
      |> put_present("legacy_uuid", Keyword.get(attrs, :legacy_uuid))

    {:ok, record} =
      EntityData.create(%{
        entity_uuid: entity.uuid,
        title: name,
        status: "published",
        data: %{"_primary_language" => primary, primary => %{"_title" => name}},
        metadata: metadata
      })

    record
  end

  defp create_operation!(name) do
    entity =
      Entities.get_entity_by_name("operation") ||
        raise "operation entity not seeded — check EntitiesRegistry blueprint provisioning"

    primary = Multilang.primary_language()

    {:ok, record} =
      EntityData.create(%{
        entity_uuid: entity.uuid,
        title: name,
        status: "published",
        data: %{"_primary_language" => primary, primary => %{"_title" => name}}
      })

    record
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
