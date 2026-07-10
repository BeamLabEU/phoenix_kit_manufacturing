defmodule PhoenixKitManufacturingTest do
  use ExUnit.Case

  # Verifies that the module correctly implements the PhoenixKit.Module
  # behaviour. These run without a database.

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitManufacturing.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitManufacturing.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns the manufacturing key" do
      assert PhoenixKitManufacturing.module_key() == "manufacturing"
    end

    test "module_name/0 returns a display name" do
      assert PhoenixKitManufacturing.module_name() == "Manufacturing"
    end

    test "enabled?/0 returns a boolean (false without DB)" do
      assert is_boolean(PhoenixKitManufacturing.enabled?())
    end

    test "enable_system/0 and disable_system/0 are exported" do
      assert function_exported?(PhoenixKitManufacturing, :enable_system, 0)
      assert function_exported?(PhoenixKitManufacturing, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitManufacturing.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key and icon uses the hero- prefix" do
      meta = PhoenixKitManufacturing.permission_metadata()
      assert meta.key == PhoenixKitManufacturing.module_key()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a list of Tab structs with the parent first" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      assert is_list(tabs)
      assert length(tabs) >= 4

      [main | _] = tabs
      assert main.id == :manufacturing
      assert main.label == "Manufacturing"
      assert is_binary(main.path)
      assert main.level == :admin
      assert main.permission == PhoenixKitManufacturing.module_key()
      assert main.group == :admin_main
      assert {PhoenixKitManufacturing.Web.DashboardLive, :index} = main.live_view
    end

    test "all tab paths use hyphens not underscores" do
      for tab <- PhoenixKitManufacturing.admin_tabs() do
        refute String.contains?(tab.path, "_")
      end
    end

    test "all tabs share the same permission (module_key)" do
      for tab <- PhoenixKitManufacturing.admin_tabs() do
        assert tab.permission == PhoenixKitManufacturing.module_key()
      end
    end

    test "all subtabs reference the main tab as parent" do
      [main | subtabs] = PhoenixKitManufacturing.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == main.id
      end
    end

    test "includes Machines and Types subtabs pointing to MachinesLive" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      machines = Enum.find(tabs, &(&1.id == :manufacturing_machines))
      types = Enum.find(tabs, &(&1.id == :manufacturing_types))

      assert machines.path == "manufacturing/machines"
      assert machines.live_view == {PhoenixKitManufacturing.Web.MachinesLive, :index}
      assert types.path == "manufacturing/machines/types"
      assert types.live_view == {PhoenixKitManufacturing.Web.MachinesLive, :types}
    end

    test "the wildcard :uuid machine-edit route is the last tab" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      last = List.last(tabs)
      assert last.id == :manufacturing_machine_edit
      assert last.path == "manufacturing/machines/:uuid/edit"
    end
  end

  describe "version/0" do
    test "matches the mix.exs version" do
      assert PhoenixKitManufacturing.version() == "0.2.0"
    end
  end

  describe "css_sources/0" do
    test "returns the OTP app atom" do
      assert PhoenixKitManufacturing.css_sources() == [:phoenix_kit_manufacturing]
    end
  end

  describe "migration_module/0" do
    alias PhoenixKitManufacturing.Migrations.Machines, as: MachinesMigration

    test "points at the module's own migration module" do
      assert PhoenixKitManufacturing.migration_module() == MachinesMigration
    end

    test "the migration module declares a positive target version" do
      assert MachinesMigration.current_version() >= 1
    end
  end

  describe "optional callbacks have defaults" do
    test "get_config/0 returns a map with :enabled" do
      config = PhoenixKitManufacturing.get_config()
      assert is_map(config)
      assert Map.has_key?(config, :enabled)
    end

    test "settings_tabs/0, user_dashboard_tabs/0, children/0 default to []" do
      assert PhoenixKitManufacturing.settings_tabs() == []
      assert PhoenixKitManufacturing.user_dashboard_tabs() == []
      assert PhoenixKitManufacturing.children() == []
    end

    test "route_module/0 defaults to nil" do
      assert PhoenixKitManufacturing.route_module() == nil
    end
  end

  describe "Paths" do
    alias PhoenixKitManufacturing.Paths

    test "index/0 points at the manufacturing module" do
      assert String.contains?(Paths.index(), "manufacturing")
    end

    test "machines/0 and types/0 return the expected subpaths" do
      assert String.ends_with?(Paths.machines(), "manufacturing/machines")
      assert String.ends_with?(Paths.types(), "manufacturing/machines/types")
    end

    test "machine_edit/1 and type_edit/1 embed the uuid" do
      uuid = "018f0000-0000-7000-8000-000000000000"
      assert String.ends_with?(Paths.machine_edit(uuid), "machines/#{uuid}/edit")
      assert String.ends_with?(Paths.type_edit(uuid), "types/#{uuid}/edit")
    end

    test "sub-paths are prefixed by index/0" do
      assert String.starts_with?(Paths.machines(), Paths.index())
      assert String.starts_with?(Paths.types(), Paths.index())
    end
  end
end
