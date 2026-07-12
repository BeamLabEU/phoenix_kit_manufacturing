defmodule PhoenixKitManufacturing.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitManufacturing.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  `phoenix_kit_settings` table is unavailable, and admin paths always get
  the default locale ("en") prefix — so our base becomes
  `/en/admin/manufacturing`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitManufacturing.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/manufacturing", PhoenixKitManufacturing.Web do
    pipe_through(:browser)

    live_session :manufacturing_test,
      layout: {PhoenixKitManufacturing.Test.Layouts, :app},
      on_mount: {PhoenixKitManufacturing.Test.Hooks, :assign_scope} do
      live("/", DashboardLive, :index)
      # Static paths before the wildcard :uuid path.
      live("/machines", MachinesLive, :index)
      live("/machines/new", MachineFormLive, :new)
      live("/machines/types", MachinesLive, :types)
      live("/machines/operations", MachinesLive, :operations)
      live("/machines/defect-reasons", MachinesLive, :defect_reasons)
      live("/machines/:uuid/edit", MachineFormLive, :edit)
      live("/machines/:uuid/operations", MachineFormLive, :operations)
      live("/machines/:uuid/files", MachineFormLive, :files)
      live("/machines/:uuid/comments", MachineFormLive, :comments)
      live("/machine-types/:uuid/template", MachineTypeTemplateLive, :edit)
    end
  end
end
