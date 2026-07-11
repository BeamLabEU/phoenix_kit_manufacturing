defmodule PhoenixKitManufacturing do
  @moduledoc """
  PhoenixKit module: manufacturing.

  Provides a dashboard plus a **Machines reference book** — machines and
  their (many-to-many) machine types, with full CRUD, activity logging and
  multilang type labels. Production orders and warehouse integration are
  planned in later milestones (see `dev_docs/DEVELOPMENT_PLAN.md`).

  The module ships its own database tables via `migration_module/0`
  (`PhoenixKitManufacturing.Migrations.Machines`); the host applies them by
  running `mix phoenix_kit.update`.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitManufacturing.Machines

  @version Mix.Project.config()[:version]

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "manufacturing"

  @impl PhoenixKit.Module
  def module_name, do: "Manufacturing"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("manufacturing_enabled", false)
  rescue
    _ -> false
  catch
    # Sandbox-owner-exited race: a non-DataCase test calls `enabled?/0`
    # right as a sibling test's owner pid has stopped. The pool checkout
    # exits before we even reach the `rescue` clause, so we have to
    # `catch :exit` separately. Returning `false` is correct — if we
    # can't read the setting, the module is effectively disabled.
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    result =
      Settings.update_boolean_setting_with_module("manufacturing_enabled", true, module_key())

    Machines.log_module_toggle(:enabled)
    result
  end

  @impl PhoenixKit.Module
  def disable_system do
    result =
      Settings.update_boolean_setting_with_module("manufacturing_enabled", false, module_key())

    Machines.log_module_toggle(:disabled)
    result
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_manufacturing]

  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitManufacturing.Migrations.Machines

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Manufacturing",
      icon: "hero-wrench-screwdriver",
      description: "Manufacturing machines and production orders"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      # Main tab — parent container. Sits in the main admin menu next to
      # Warehouse (priority 153); its own page is the module dashboard.
      %Tab{
        id: :manufacturing,
        label: "Manufacturing",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-wrench-screwdriver",
        path: "manufacturing",
        priority: 154,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        match: :prefix,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        live_view: {PhoenixKitManufacturing.Web.DashboardLive, :index}
      },
      # Subtabs — Dashboard (landing), Machines, Types, Operations, Defect Reasons
      %Tab{
        id: :manufacturing_dashboard,
        label: "Dashboard",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-home",
        path: "manufacturing",
        priority: 155,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :manufacturing,
        live_view: {PhoenixKitManufacturing.Web.DashboardLive, :index}
      },
      %Tab{
        id: :manufacturing_machines,
        label: "Machines",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-cog-6-tooth",
        path: "manufacturing/machines",
        priority: 156,
        level: :admin,
        permission: module_key(),
        # Match the list page + its own sub-pages (new / edit) but NOT the
        # sibling `machines/types*` subtree. A bare `:prefix` would swallow
        # types; `:exact` misses /new and /:uuid/edit.
        match: {:regex, ~r{(?:^|/)manufacturing/machines(?:/new|/[^/]+/edit)?$}},
        parent: :manufacturing,
        live_view: {PhoenixKitManufacturing.Web.MachinesLive, :index}
      },
      %Tab{
        id: :manufacturing_types,
        label: "Types",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-tag",
        path: "manufacturing/machines/types",
        priority: 157,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        live_view: {PhoenixKitManufacturing.Web.MachinesLive, :types}
      },
      %Tab{
        id: :manufacturing_operations,
        label: "Operations",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-clock",
        path: "manufacturing/machines/operations",
        priority: 158,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        live_view: {PhoenixKitManufacturing.Web.MachinesLive, :operations}
      },
      %Tab{
        id: :manufacturing_defect_reasons,
        label: "Defect Reasons",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-exclamation-triangle",
        path: "manufacturing/machines/defect-reasons",
        priority: 165,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        live_view: {PhoenixKitManufacturing.Web.MachinesLive, :defect_reasons}
      },
      # Static paths MUST come before wildcard :uuid paths.
      %Tab{
        id: :manufacturing_machine_new,
        label: "New Machine",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "manufacturing/machines/new",
        priority: 159,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.MachineFormLive, :new}
      },
      %Tab{
        id: :manufacturing_type_new,
        label: "New Type",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "manufacturing/machines/types/new",
        priority: 160,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.MachineTypeFormLive, :new}
      },
      %Tab{
        id: :manufacturing_operation_new,
        label: "New Operation",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "manufacturing/machines/operations/new",
        priority: 161,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.OperationFormLive, :new}
      },
      %Tab{
        id: :manufacturing_defect_reason_new,
        label: "New Defect Reason",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-plus",
        path: "manufacturing/machines/defect-reasons/new",
        priority: 166,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.DefectReasonFormLive, :new}
      },
      # Wildcard :uuid routes LAST.
      %Tab{
        id: :manufacturing_type_edit,
        label: "Edit Type",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "manufacturing/machines/types/:uuid/edit",
        priority: 162,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.MachineTypeFormLive, :edit}
      },
      %Tab{
        id: :manufacturing_machine_edit,
        label: "Edit Machine",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "manufacturing/machines/:uuid/edit",
        priority: 163,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.MachineFormLive, :edit}
      },
      %Tab{
        id: :manufacturing_operation_edit,
        label: "Edit Operation",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "manufacturing/machines/operations/:uuid/edit",
        priority: 164,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.OperationFormLive, :edit}
      },
      %Tab{
        id: :manufacturing_defect_reason_edit,
        label: "Edit Defect Reason",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-pencil-square",
        path: "manufacturing/machines/defect-reasons/:uuid/edit",
        priority: 167,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.DefectReasonFormLive, :edit}
      }
    ]
  end
end
