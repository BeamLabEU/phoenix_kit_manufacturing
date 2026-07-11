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
    alias PhoenixKit.Dashboard.Tab

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

    test "all tabs carry the module's gettext backend and default domain" do
      for tab <- PhoenixKitManufacturing.admin_tabs() do
        assert tab.gettext_backend == PhoenixKitManufacturing.Gettext
        assert tab.gettext_domain == "default"
      end
    end

    test "sidebar labels resolve through the gettext backend" do
      main = Enum.find(PhoenixKitManufacturing.admin_tabs(), &(&1.id == :manufacturing))

      dashboard =
        Enum.find(PhoenixKitManufacturing.admin_tabs(), &(&1.id == :manufacturing_dashboard))

      # Each ExUnit test runs in its own process, so this process-scoped
      # locale change doesn't leak into other tests.
      Gettext.put_locale(PhoenixKitManufacturing.Gettext, "et")

      assert Tab.localized_label(main) == "Tootmine"
      assert Tab.localized_label(dashboard) == "Töölaud"
    end

    test "all subtabs reference the main tab as parent" do
      [main | subtabs] = PhoenixKitManufacturing.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == main.id
      end
    end

    test "includes Machines, Types, Operations and Defect Reasons subtabs pointing to MachinesLive" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      machines = Enum.find(tabs, &(&1.id == :manufacturing_machines))
      types = Enum.find(tabs, &(&1.id == :manufacturing_types))
      operations = Enum.find(tabs, &(&1.id == :manufacturing_operations))
      defect_reasons = Enum.find(tabs, &(&1.id == :manufacturing_defect_reasons))

      assert machines.path == "manufacturing/machines"
      assert machines.live_view == {PhoenixKitManufacturing.Web.MachinesLive, :index}
      assert types.path == "manufacturing/machines/types"
      assert types.live_view == {PhoenixKitManufacturing.Web.MachinesLive, :types}
      assert operations.path == "manufacturing/machines/operations"
      assert operations.live_view == {PhoenixKitManufacturing.Web.MachinesLive, :operations}
      assert defect_reasons.path == "manufacturing/machines/defect-reasons"

      assert defect_reasons.live_view ==
               {PhoenixKitManufacturing.Web.MachinesLive, :defect_reasons}
    end

    test "includes hidden New/Edit Operation tabs pointing to OperationFormLive" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      new_tab = Enum.find(tabs, &(&1.id == :manufacturing_operation_new))
      edit_tab = Enum.find(tabs, &(&1.id == :manufacturing_operation_edit))

      assert new_tab.path == "manufacturing/machines/operations/new"
      assert new_tab.visible == false
      assert new_tab.live_view == {PhoenixKitManufacturing.Web.OperationFormLive, :new}

      assert edit_tab.path == "manufacturing/machines/operations/:uuid/edit"
      assert edit_tab.visible == false
      assert edit_tab.live_view == {PhoenixKitManufacturing.Web.OperationFormLive, :edit}
    end

    test "includes hidden New/Edit Defect Reason tabs pointing to DefectReasonFormLive" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      new_tab = Enum.find(tabs, &(&1.id == :manufacturing_defect_reason_new))
      edit_tab = Enum.find(tabs, &(&1.id == :manufacturing_defect_reason_edit))

      assert new_tab.path == "manufacturing/machines/defect-reasons/new"
      assert new_tab.visible == false
      assert new_tab.live_view == {PhoenixKitManufacturing.Web.DefectReasonFormLive, :new}

      assert edit_tab.path == "manufacturing/machines/defect-reasons/:uuid/edit"
      assert edit_tab.visible == false
      assert edit_tab.live_view == {PhoenixKitManufacturing.Web.DefectReasonFormLive, :edit}
    end

    test "the Machines tab's regex match does not swallow the Operations subtree" do
      machines_tab =
        Enum.find(PhoenixKitManufacturing.admin_tabs(), &(&1.id == :manufacturing_machines))

      refute Tab.matches_path?(
               machines_tab,
               "manufacturing/machines/operations"
             )

      refute Tab.matches_path?(
               machines_tab,
               "manufacturing/machines/operations/new"
             )

      refute Tab.matches_path?(
               machines_tab,
               "manufacturing/machines/operations/018f0000-0000-7000-8000-000000000000/edit"
             )
    end

    test "the Machines tab's regex match does not swallow the Defect Reasons subtree" do
      machines_tab =
        Enum.find(PhoenixKitManufacturing.admin_tabs(), &(&1.id == :manufacturing_machines))

      refute Tab.matches_path?(
               machines_tab,
               "manufacturing/machines/defect-reasons"
             )

      refute Tab.matches_path?(
               machines_tab,
               "manufacturing/machines/defect-reasons/new"
             )

      refute Tab.matches_path?(
               machines_tab,
               "manufacturing/machines/defect-reasons/018f0000-0000-7000-8000-000000000000/edit"
             )
    end

    test "the wildcard :uuid defect-reason-edit route is the last tab" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      last = List.last(tabs)
      assert last.id == :manufacturing_defect_reason_edit
      assert last.path == "manufacturing/machines/defect-reasons/:uuid/edit"
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

    test "operations/0 and operation_new/0 return the expected subpaths" do
      assert String.ends_with?(Paths.operations(), "manufacturing/machines/operations")
      assert String.ends_with?(Paths.operation_new(), "manufacturing/machines/operations/new")
    end

    test "machine_edit/1 and type_edit/1 embed the uuid" do
      uuid = "018f0000-0000-7000-8000-000000000000"
      assert String.ends_with?(Paths.machine_edit(uuid), "machines/#{uuid}/edit")
      assert String.ends_with?(Paths.type_edit(uuid), "types/#{uuid}/edit")
    end

    test "operation_edit/1 embeds the uuid" do
      uuid = "018f0000-0000-7000-8000-000000000000"
      assert String.ends_with?(Paths.operation_edit(uuid), "operations/#{uuid}/edit")
    end

    test "sub-paths are prefixed by index/0" do
      assert String.starts_with?(Paths.machines(), Paths.index())
      assert String.starts_with?(Paths.types(), Paths.index())
      assert String.starts_with?(Paths.operations(), Paths.index())
    end
  end
end
