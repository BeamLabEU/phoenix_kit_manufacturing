defmodule PhoenixKitManufacturing do
  @moduledoc """
  PhoenixKit module: machines and production orders.

  Dashboard-only scaffold — no database schemas or migrations yet.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

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

    PhoenixKit.Activity.log(%{
      action: "manufacturing_module.enabled",
      mode: "manual",
      resource_type: "module",
      metadata: %{"module_key" => module_key()}
    })

    result
  end

  @impl PhoenixKit.Module
  def disable_system do
    result =
      Settings.update_boolean_setting_with_module("manufacturing_enabled", false, module_key())

    PhoenixKit.Activity.log(%{
      action: "manufacturing_module.disabled",
      mode: "manual",
      resource_type: "module",
      metadata: %{"module_key" => module_key()}
    })

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
      %Tab{
        id: :manufacturing,
        label: "Manufacturing",
        icon: "hero-wrench-screwdriver",
        path: "manufacturing",
        match: :exact,
        priority: 154,
        level: :admin,
        permission: module_key(),
        group: :admin_main,
        live_view: {PhoenixKitManufacturing.Web.DashboardLive, :index}
      }
    ]
  end
end
