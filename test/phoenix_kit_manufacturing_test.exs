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

    test "does not include the removed Type/Operation/Defect-Reason New/Edit tabs" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      ids = Enum.map(tabs, & &1.id)

      refute :manufacturing_type_new in ids
      refute :manufacturing_operation_new in ids
      refute :manufacturing_defect_reason_new in ids
      refute :manufacturing_type_edit in ids
      refute :manufacturing_operation_edit in ids
      refute :manufacturing_defect_reason_edit in ids
    end

    test "includes hidden Machine Operations/Files/Comments tabs pointing to MachineFormLive" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      operations_tab = Enum.find(tabs, &(&1.id == :manufacturing_machine_operations))
      files_tab = Enum.find(tabs, &(&1.id == :manufacturing_machine_files))
      comments_tab = Enum.find(tabs, &(&1.id == :manufacturing_machine_comments))

      assert operations_tab.path == "manufacturing/machines/:uuid/operations"
      assert operations_tab.visible == false

      assert operations_tab.live_view ==
               {PhoenixKitManufacturing.Web.MachineFormLive, :operations}

      assert files_tab.path == "manufacturing/machines/:uuid/files"
      assert files_tab.visible == false
      assert files_tab.live_view == {PhoenixKitManufacturing.Web.MachineFormLive, :files}

      assert comments_tab.path == "manufacturing/machines/:uuid/comments"
      assert comments_tab.visible == false
      assert comments_tab.live_view == {PhoenixKitManufacturing.Web.MachineFormLive, :comments}
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

    test "the Machines tab's regex match still highlights the machine card's Operations/Files/Comments subtabs" do
      machines_tab =
        Enum.find(PhoenixKitManufacturing.admin_tabs(), &(&1.id == :manufacturing_machines))

      uuid = "018f0000-0000-7000-8000-000000000000"

      assert Tab.matches_path?(machines_tab, "manufacturing/machines/#{uuid}/operations")
      assert Tab.matches_path?(machines_tab, "manufacturing/machines/#{uuid}/files")
      assert Tab.matches_path?(machines_tab, "manufacturing/machines/#{uuid}/comments")
    end

    test "the wildcard :uuid machine-comments route is the last machine-card tab" do
      tabs = PhoenixKitManufacturing.admin_tabs()
      comments_index = Enum.find_index(tabs, &(&1.id == :manufacturing_machine_comments))
      assert comments_index, "expected :manufacturing_machine_comments to be present"

      comments = Enum.at(tabs, comments_index)
      assert comments.path == "manufacturing/machines/:uuid/comments"

      # The other machine-card hidden tab routes (also :uuid-wildcard, see
      # Web.MachineFormLive's moduledoc "Tabs") must sit somewhere before
      # the final machine-card tab too — same "wildcard routes last as a
      # block" ordering convention as manufacturing_machine_edit itself.
      for id <- [
            :manufacturing_machine_edit,
            :manufacturing_machine_operations,
            :manufacturing_machine_files
          ] do
        index = Enum.find_index(tabs, &(&1.id == id))
        assert index, "expected #{id} to be present in admin_tabs/0"
        assert index < comments_index
      end

      # `:manufacturing_machine_type_template` is a *different* wildcard
      # :uuid route on its own literal prefix
      # (`manufacturing/machine-types/:uuid/template` — "machine-types",
      # not "machines"), so it can never shadow any machine-card route
      # regardless of declaration order (see `Web.MachineTypeTemplateLive`
      # moduledoc) — it's fine for it to sit after the machine-card block,
      # making it the actual last tab overall.
      last = List.last(tabs)
      assert last.id == :manufacturing_machine_type_template
      assert last.path == "manufacturing/machine-types/:uuid/template"
    end

    test "the machine type template tab is hidden and points at MachineTypeTemplateLive" do
      template_tab =
        Enum.find(
          PhoenixKitManufacturing.admin_tabs(),
          &(&1.id == :manufacturing_machine_type_template)
        )

      assert template_tab.path == "manufacturing/machine-types/:uuid/template"
      assert template_tab.visible == false
      assert template_tab.parent == :manufacturing

      assert template_tab.live_view ==
               {PhoenixKitManufacturing.Web.MachineTypeTemplateLive, :edit}
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

  describe "optional callbacks have defaults" do
    test "get_config/0 returns a map with :enabled" do
      config = PhoenixKitManufacturing.get_config()
      assert is_map(config)
      assert Map.has_key?(config, :enabled)
    end

    test "settings_tabs/0, user_dashboard_tabs/0 default to []" do
      assert PhoenixKitManufacturing.settings_tabs() == []
      assert PhoenixKitManufacturing.user_dashboard_tabs() == []
    end

    test "route_module/0 defaults to nil" do
      assert PhoenixKitManufacturing.route_module() == nil
    end
  end

  describe "children/0" do
    test "wires the EntitiesRegistry into the module's supervision tree" do
      assert PhoenixKitManufacturing.children() == [PhoenixKitManufacturing.EntitiesRegistry]
    end
  end

  describe "Paths" do
    alias PhoenixKitManufacturing.Paths

    test "index/0 points at the manufacturing module" do
      assert String.contains?(Paths.index(), "manufacturing")
    end

    test "machines/0 returns the expected subpath" do
      assert String.ends_with?(Paths.machines(), "manufacturing/machines")
    end

    test "types/0, operations/0 and defect_reasons/0 point at the entities admin UI" do
      assert String.ends_with?(Paths.types(), "entities/machine_type/data")
      assert String.ends_with?(Paths.operations(), "entities/operation/data")
      assert String.ends_with?(Paths.defect_reasons(), "entities/defect_reason/data")
    end

    test "machine_edit/1 embeds the uuid" do
      uuid = "018f0000-0000-7000-8000-000000000000"
      assert String.ends_with?(Paths.machine_edit(uuid), "machines/#{uuid}/edit")
    end

    test "machine_operations/1, machine_files/1 and machine_comments/1 embed the uuid" do
      uuid = "018f0000-0000-7000-8000-000000000000"
      assert String.ends_with?(Paths.machine_operations(uuid), "machines/#{uuid}/operations")
      assert String.ends_with?(Paths.machine_files(uuid), "machines/#{uuid}/files")
      assert String.ends_with?(Paths.machine_comments(uuid), "machines/#{uuid}/comments")
    end

    test "machines/0 is prefixed by index/0" do
      assert String.starts_with?(Paths.machines(), Paths.index())
    end

    test "types/0, operations/0 and defect_reasons/0 are entities routes, not module subpaths" do
      refute String.starts_with?(Paths.types(), Paths.index())
      refute String.starts_with?(Paths.operations(), Paths.index())
      refute String.starts_with?(Paths.defect_reasons(), Paths.index())
    end
  end
end
