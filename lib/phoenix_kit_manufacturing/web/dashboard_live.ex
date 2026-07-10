defmodule PhoenixKitManufacturing.Web.DashboardLive do
  @moduledoc """
  Admin dashboard for the Manufacturing module.

  Shows at-a-glance counts for the machines reference book and quick links
  into its sections. The admin layout (sidebar, header, theme) is applied
  automatically by PhoenixKit's `on_mount` hook; do not wrap this render in
  `LayoutWrapper`.

  All counts are loaded defensively — if the host has not yet run
  `mix phoenix_kit.update` (so the module's tables do not exist), the
  queries fail softly and the dashboard renders zeros rather than crashing.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  alias PhoenixKitManufacturing.{Machines, Paths}

  @impl true
  def mount(_params, _session, socket) do
    # mount/3 runs twice (HTTP + WebSocket) — no DB queries here. Counts are
    # loaded in handle_params/3, which runs once per navigation.
    {:ok,
     socket
     |> assign(:page_title, gettext("Manufacturing"))
     |> assign(:machine_count, nil)
     |> assign(:type_count, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:machine_count, safe_count(&Machines.count_machines/0))
     |> assign(:type_count, safe_count(&Machines.count_machine_types/0))}
  end

  # Counts degrade to nil (rendered as "—") when the tables are missing or
  # the DB is unavailable, so the dashboard never 500s on a fresh host.
  defp safe_count(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp display(nil), do: "—"
  defp display(n), do: Integer.to_string(n)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl">
            <.icon name="hero-wrench-screwdriver" class="w-6 h-6" />
            {gettext("Manufacturing")}
          </h2>
          <p class="text-base-content/70">
            {gettext(
              "Manage your machines reference book. Production orders and warehouse integration are coming soon."
            )}
          </p>
          <div class="card-actions mt-2">
            <.link navigate={Paths.machines()} class="btn btn-primary btn-sm">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> {gettext("Machines")}
            </.link>
            <.link navigate={Paths.types()} class="btn btn-ghost btn-sm">
              <.icon name="hero-tag" class="w-4 h-4" /> {gettext("Types")}
            </.link>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <.link navigate={Paths.machines()} class="stat bg-base-100 rounded-box shadow hover:bg-base-200 transition-colors">
          <div class="stat-figure text-primary">
            <.icon name="hero-cog-6-tooth" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Machines")}</div>
          <div class="stat-value">{display(@machine_count)}</div>
          <div class="stat-desc">{gettext("In the reference book")}</div>
        </.link>

        <.link navigate={Paths.types()} class="stat bg-base-100 rounded-box shadow hover:bg-base-200 transition-colors">
          <div class="stat-figure text-secondary">
            <.icon name="hero-tag" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Machine Types")}</div>
          <div class="stat-value">{display(@type_count)}</div>
          <div class="stat-desc">{gettext("Categories")}</div>
        </.link>

        <div class="stat bg-base-100 rounded-box shadow">
          <div class="stat-figure text-base-content/40">
            <.icon name="hero-clipboard-document-list" class="w-8 h-8" />
          </div>
          <div class="stat-title">{gettext("Production Orders")}</div>
          <div class="stat-value text-base-content/40">0</div>
          <div class="stat-desc">{gettext("Coming soon")}</div>
        </div>
      </div>
    </div>
    """
  end
end
