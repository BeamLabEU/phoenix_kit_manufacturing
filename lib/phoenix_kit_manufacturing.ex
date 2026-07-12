defmodule PhoenixKitManufacturing do
  @moduledoc """
  PhoenixKit module: manufacturing.

  Provides a dashboard plus a **Machines reference book** — machines with
  full CRUD and activity logging, plus many-to-many links to machine types
  and operations. Machine types, operations, and defect reasons are
  `phoenix_kit_entities`-backed directories (migration V5) rather than
  module-owned CRUD — see `PhoenixKitManufacturing.EntitiesRegistry` and
  `dev_docs/ENTITIES_MIGRATION_SPEC.md`. Production orders and warehouse
  integration are planned in later milestones (see
  `dev_docs/DEVELOPMENT_PLAN.md`).

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
  def children, do: [PhoenixKitManufacturing.EntitiesRegistry]

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
        # Match the list page + its own sub-pages (new / edit / the machine
        # card's operations/files/comments subtabs) but NOT the sibling
        # `machines/types*` subtree. A bare `:prefix` would swallow types;
        # `:exact` misses /new and /:uuid/edit (and the card subtabs).
        match:
          {:regex,
           ~r{(?:^|/)manufacturing/machines(?:/new|/[^/]+/(?:edit|operations|files|comments))?$}},
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
      # Wildcard :uuid routes LAST.
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
      # Machine card in-page tabs (Operations/Files/Comments) — hidden CRUD
      # routes so each tab is directly linkable/bookmarkable, same
      # `hidden_crud_tabs` convention as `PhoenixKitWarehouse`'s document
      # forms. See `Web.MachineFormLive`'s moduledoc ("Tabs").
      %Tab{
        id: :manufacturing_machine_operations,
        label: "Machine Operations",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-clock",
        path: "manufacturing/machines/:uuid/operations",
        priority: 168,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.MachineFormLive, :operations}
      },
      %Tab{
        id: :manufacturing_machine_files,
        label: "Machine Files",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-paper-clip",
        path: "manufacturing/machines/:uuid/files",
        priority: 169,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.MachineFormLive, :files}
      },
      %Tab{
        id: :manufacturing_machine_comments,
        label: "Machine Comments",
        gettext_backend: PhoenixKitManufacturing.Gettext,
        gettext_domain: "default",
        icon: "hero-chat-bubble-left-right",
        path: "manufacturing/machines/:uuid/comments",
        priority: 170,
        level: :admin,
        permission: module_key(),
        parent: :manufacturing,
        visible: false,
        live_view: {PhoenixKitManufacturing.Web.MachineFormLive, :comments}
      }
    ]
  end
end
