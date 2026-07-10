defmodule PhoenixKitManufacturing.Web.DashboardLive do
  @moduledoc """
  Admin dashboard for the Manufacturing module.

  Stub page — no database-backed data yet. The admin layout (sidebar,
  header, theme) is applied automatically by PhoenixKit's `on_mount` hook;
  do not wrap this render in `LayoutWrapper`.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, dgettext("default", "Manufacturing"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl">
            <.icon name="hero-wrench-screwdriver" class="w-6 h-6" />
            {dgettext("default", "Manufacturing")}
          </h2>
          <p class="text-base-content/70">
            {dgettext(
              "default",
              "This module is under development. Machines and production orders will appear here."
            )}
          </p>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div class="stat bg-base-100 rounded-box shadow">
          <div class="stat-figure text-base-content/40">
            <.icon name="hero-cog-6-tooth" class="w-8 h-8" />
          </div>
          <div class="stat-title">{dgettext("default", "Machines")}</div>
          <div class="stat-value text-base-content/40">0</div>
          <div class="stat-desc">{dgettext("default", "Coming soon")}</div>
        </div>

        <div class="stat bg-base-100 rounded-box shadow">
          <div class="stat-figure text-base-content/40">
            <.icon name="hero-clipboard-document-list" class="w-8 h-8" />
          </div>
          <div class="stat-title">
            {dgettext("default", "Production Orders")}
          </div>
          <div class="stat-value text-base-content/40">0</div>
          <div class="stat-desc">{dgettext("default", "Coming soon")}</div>
        </div>
      </div>
    </div>
    """
  end
end
