defmodule PhoenixKitManufacturing.EntitiesRegistryTest do
  # Integration tests — need PostgreSQL (creates real entity/entity_data
  # rows), excluded when the DB is unavailable (see test_helper.exs). The
  # registry is a GenServer started per-test via `start_supervised!/1` and
  # queries the DB from its own process, so the sandbox must run in shared
  # mode (`async: false`) — same pattern as `Andi.Orders.StatusRegistryTest`.
  use PhoenixKitManufacturing.DataCase, async: false

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitManufacturing.EntitiesRegistry

  setup do
    start_supervised!(EntitiesRegistry)

    # `EntitiesRegistry`'s own blueprint provisioning (run once, unsandboxed,
    # by `test_helper.exs` before `ExUnit.start/1`, and again idempotently
    # by `start_supervised!/1` just above) already seeded a permanent
    # "machine_type" / "operation" / "defect_reason" entity into the test
    # database's real committed data — `Entities.create_entity/2` would hit
    # its `unique_constraint(:name)` and return `{:error, changeset}` if
    # called again with the same name here. Reuse the existing entity
    # instead, same idempotent lookup `ensure_blueprint_entity/2` itself
    # does.
    machine_type = ensure_entity!("machine_type", [])

    operation =
      ensure_entity!("operation", [
        %{"type" => "text", "key" => "unit", "label" => "Unit"},
        %{"type" => "number", "key" => "base_time_norm_seconds", "label" => "Base time norm"}
      ])

    %{machine_type: machine_type, operation: operation}
  end

  # Pure mapping logic, but still touches `PhoenixKit.Settings` (via
  # `Multilang.enabled_languages/0`) so it needs the DB same as everything
  # else in this file — see the moduletag note above.
  describe "normalize_locale/1" do
    test "nil resolves to the primary language" do
      assert EntitiesRegistry.normalize_locale(nil) == "en-US"
    end

    test "an already-enabled BCP-47 code passes through unchanged" do
      assert EntitiesRegistry.normalize_locale("en-US") == "en-US"
    end

    test "a bare gettext code resolves to the enabled dialect sharing its prefix" do
      assert EntitiesRegistry.normalize_locale("en") == "en-US"
    end

    test "a locale with no enabled match falls back to the primary language" do
      assert EntitiesRegistry.normalize_locale("et") == "en-US"
      assert EntitiesRegistry.normalize_locale("xx-YY") == "en-US"
    end
  end

  describe "ready?/0" do
    test "is true once the registry has completed its initial load" do
      assert EntitiesRegistry.ready?()
    end
  end

  describe "list/3" do
    test "resolves the primary-language name and carries metadata through unchanged",
         %{machine_type: machine_type} do
      data =
        multilang_data("en-US", %{
          "en-US" => %{"_title" => "CNC Mill"},
          "et-EE" => %{"_title" => "CNC-frees"}
        })

      {:ok, record} =
        EntityData.create(%{
          entity_uuid: machine_type.uuid,
          title: "CNC Mill",
          status: "published",
          data: data,
          metadata: %{
            "field_template" => [
              %{"key" => "power_kw", "label" => "Power (kW)", "type" => "number"}
            ],
            "legacy_uuid" => Ecto.UUID.generate()
          },
          created_by_uuid: Ecto.UUID.generate()
        })

      EntitiesRegistry.reload()

      assert [item] = EntitiesRegistry.list(:machine_type, "en", status: "published")
      assert item.uuid == record.uuid
      assert item.name == "CNC Mill"
      assert item.status == "published"
      assert item.position == record.position

      assert item.metadata["field_template"] == [
               %{"key" => "power_kw", "label" => "Power (kW)", "type" => "number"}
             ]

      # A locale the host hasn't enabled (fresh install, Languages module
      # off) falls back to the primary title rather than the "et-EE"
      # override — see the registry's moduledoc.
      assert [fallback_item] = EntitiesRegistry.list(:machine_type, "et", status: "published")
      assert fallback_item.name == "CNC Mill"
    end

    test "filters by :status; without it, returns every cached (non-trashed) status",
         %{machine_type: machine_type} do
      {:ok, draft} =
        EntityData.create(%{
          entity_uuid: machine_type.uuid,
          title: "Draft type",
          status: "draft",
          created_by_uuid: Ecto.UUID.generate()
        })

      {:ok, published} =
        EntityData.create(%{
          entity_uuid: machine_type.uuid,
          title: "Published type",
          status: "published",
          created_by_uuid: Ecto.UUID.generate()
        })

      EntitiesRegistry.reload()

      published_uuids =
        :machine_type
        |> EntitiesRegistry.list("en", status: "published")
        |> Enum.map(& &1.uuid)

      assert published_uuids == [published.uuid]

      all_uuids = :machine_type |> EntitiesRegistry.list("en") |> Enum.map(& &1.uuid)
      assert draft.uuid in all_uuids
      assert published.uuid in all_uuids
    end

    test "operation records read unit/base_time_norm_seconds from the primary block only",
         %{operation: operation} do
      data =
        multilang_data("en-US", %{
          "en-US" => %{"_title" => "Cutting", "unit" => "pcs", "base_time_norm_seconds" => 120},
          "et-EE" => %{"_title" => "Loikamine"}
        })

      {:ok, _record} =
        EntityData.create(%{
          entity_uuid: operation.uuid,
          title: "Cutting",
          status: "published",
          data: data,
          created_by_uuid: Ecto.UUID.generate()
        })

      EntitiesRegistry.reload()

      assert [item] = EntitiesRegistry.list(:operation, "en", status: "published")
      assert item.unit == "pcs"
      assert item.base_time_norm_seconds == 120
    end
  end

  describe "get/2" do
    test "returns the cached record by uuid, primary-titled, or nil", %{
      machine_type: machine_type
    } do
      {:ok, record} =
        EntityData.create(%{
          entity_uuid: machine_type.uuid,
          title: "Laser cutter",
          status: "published",
          created_by_uuid: Ecto.UUID.generate()
        })

      EntitiesRegistry.reload()

      fetched = EntitiesRegistry.get(record.uuid, :machine_type)
      assert fetched.uuid == record.uuid
      assert fetched.name == "Laser cutter"

      assert EntitiesRegistry.get(Ecto.UUID.generate(), :machine_type) == nil
      assert EntitiesRegistry.get(nil, :machine_type) == nil
    end
  end

  describe "label/3" do
    test "resolves the primary-language title and returns \"Unknown\" for a missing/nil uuid",
         %{machine_type: machine_type} do
      {:ok, record} =
        EntityData.create(%{
          entity_uuid: machine_type.uuid,
          title: "Press",
          status: "published",
          created_by_uuid: Ecto.UUID.generate()
        })

      EntitiesRegistry.reload()

      assert EntitiesRegistry.label(record.uuid, :machine_type, "en") == "Press"
      assert EntitiesRegistry.label(nil, :machine_type, "en") == "Unknown"
      assert EntitiesRegistry.label(Ecto.UUID.generate(), :machine_type, "en") == "Unknown"
    end
  end

  describe "reload/0" do
    test "picks up new records and drops trashed ones from the cache",
         %{machine_type: machine_type} do
      assert EntitiesRegistry.list(:machine_type, "en") == []

      {:ok, record} =
        EntityData.create(%{
          entity_uuid: machine_type.uuid,
          title: "Router",
          status: "published",
          created_by_uuid: Ecto.UUID.generate()
        })

      EntitiesRegistry.reload()

      assert [%{uuid: uuid}] = EntitiesRegistry.list(:machine_type, "en")
      assert uuid == record.uuid
      assert EntitiesRegistry.get(record.uuid, :machine_type) != nil

      {:ok, _trashed} = EntityData.trash(record)
      EntitiesRegistry.reload()

      assert EntitiesRegistry.list(:machine_type, "en") == []
      assert EntitiesRegistry.get(record.uuid, :machine_type) == nil
    end
  end

  ## Helpers

  defp multilang_data(primary_locale, blocks) do
    Map.put(blocks, "_primary_language", primary_locale)
  end

  defp ensure_entity!(name, fields_definition) do
    Entities.get_entity_by_name(name) ||
      case Entities.create_entity(%{
             name: name,
             display_name: name,
             display_name_plural: name,
             fields_definition: fields_definition,
             created_by_uuid: Ecto.UUID.generate()
           }) do
        {:ok, entity} -> entity
      end
  end
end
