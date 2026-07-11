defmodule PhoenixKitManufacturing.Web.MachinesLive do
  @moduledoc """
  Landing page for the Machines reference book.

  Handles two actions, dispatched by `live_action`:

    * `:index` — list of machines
    * `:types` — list of machine types

  The Machines / Types switcher lives in the PhoenixKit admin dashboard's
  subtab nav (`:manufacturing_machines` / `:manufacturing_types`), so it is
  not duplicated in the page body.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKitManufacturing.{Errors, Machines, Paths}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Machines"),
       machines: [],
       machine_types: [],
       confirm_delete: nil,
       locale: socket.assigns[:current_locale] || Gettext.get_locale()
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action || :index

    socket =
      socket
      |> assign(:active_tab, action)
      |> assign(:page_title, tab_title(action))
      |> assign(:confirm_delete, nil)
      |> load_data(action)

    {:noreply, socket}
  end

  defp tab_title(:index), do: gettext("Machines")
  defp tab_title(:types), do: gettext("Machine Types")

  defp load_data(socket, :index) do
    assign(socket, :machines, Machines.list_machines())
  rescue
    error ->
      Logger.error("Failed to load machines: #{inspect(error)}")
      put_flash(socket, :error, gettext("Failed to load machines."))
  end

  defp load_data(socket, :types) do
    assign(socket, :machine_types, Machines.list_machine_types())
  rescue
    error ->
      Logger.error("Failed to load machine types: #{inspect(error)}")
      put_flash(socket, :error, gettext("Failed to load machine types."))
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("delete_machine", _params, socket) do
    case socket.assigns.confirm_delete do
      {"machine", uuid} -> do_delete_item(socket, :machine, uuid)
      _ -> {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event("delete_machine_type", _params, socket) do
    case socket.assigns.confirm_delete do
      {"machine_type", uuid} -> do_delete_item(socket, :machine_type, uuid)
      _ -> {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  # Defensive catch-all for unmatched messages (e.g. future PubSub
  # broadcasts). Logs at :debug rather than crashing the LiveView.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[MachinesLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp do_delete_item(socket, kind, uuid) do
    with %{} = record <- fetch_for_delete(kind, uuid),
         {:ok, _} <- delete_for_kind(kind, record, socket) do
      {:noreply,
       socket
       |> put_flash(:info, deleted_message(kind))
       |> assign(:confirm_delete, nil)
       |> load_data(reload_action(kind))}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Errors.message(not_found_atom(kind)))
         |> assign(:confirm_delete, nil)
         |> load_data(reload_action(kind))}

      {:error, reason} ->
        Logger.error("Failed to delete #{kind} #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, Errors.message(delete_failed_atom(kind)))
         |> assign(:confirm_delete, nil)
         |> load_data(reload_action(kind))}
    end
  rescue
    error ->
      Logger.error("Unexpected error deleting #{kind} #{uuid}: #{inspect(error)}")

      {:noreply,
       socket
       |> put_flash(:error, Errors.message(:unexpected))
       |> assign(:confirm_delete, nil)}
  end

  defp fetch_for_delete(:machine, uuid), do: Machines.get_machine(uuid)
  defp fetch_for_delete(:machine_type, uuid), do: Machines.get_machine_type(uuid)

  defp delete_for_kind(:machine, record, socket),
    do: Machines.delete_machine(record, actor_opts(socket))

  defp delete_for_kind(:machine_type, record, socket),
    do: Machines.delete_machine_type(record, actor_opts(socket))

  defp deleted_message(:machine), do: gettext("Machine deleted.")
  defp deleted_message(:machine_type), do: gettext("Machine type deleted.")

  defp not_found_atom(:machine), do: :machine_not_found
  defp not_found_atom(:machine_type), do: :machine_type_not_found

  defp delete_failed_atom(:machine), do: :machine_delete_failed
  defp delete_failed_atom(:machine_type), do: :machine_type_delete_failed

  defp reload_action(:machine), do: :index
  defp reload_action(:machine_type), do: :types

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <.admin_page_header
        title={if @active_tab == :types, do: gettext("Machine Types"), else: gettext("Machines")}
        subtitle={
          if @active_tab == :types,
            do: gettext("Categories used to tag machines."),
            else: gettext("Production equipment reference book.")
        }
      >
        <:actions>
          <.link
            :if={@active_tab == :index}
            navigate={Paths.machine_new()}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Machine")}
          </.link>
          <.link
            :if={@active_tab == :types}
            navigate={Paths.type_new()}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Type")}
          </.link>
        </:actions>
      </.admin_page_header>

      <div :if={@active_tab == :index}>
        <.machines_table machines={@machines} locale={@locale} />
      </div>

      <div :if={@active_tab == :types}>
        <.types_table machine_types={@machine_types} />
      </div>

      <.confirm_modal
        show={match?({"machine", _}, @confirm_delete)}
        on_confirm="delete_machine"
        on_cancel="cancel_delete"
        title={gettext("Delete Machine")}
        title_icon="hero-trash"
        messages={[{:warning, gettext("This will permanently delete this machine. This cannot be undone.")}]}
        confirm_text={gettext("Delete")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"machine_type", _}, @confirm_delete)}
        on_confirm="delete_machine_type"
        on_cancel="cancel_delete"
        title={gettext("Delete Machine Type")}
        title_icon="hero-trash"
        messages={[{:warning, gettext("This will permanently delete this machine type. Machines using it will lose the type association.")}]}
        confirm_text={gettext("Delete")}
        danger={true}
      />
    </div>
    """
  end

  defp machines_table(assigns) do
    ~H"""
    <div :if={@machines == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{gettext("No machines yet.")}</p>
      </div>
    </div>

    <div :if={@machines != []}>
      <.table_default
        variant="zebra"
        size="sm"
        toggleable={true}
        id="machines-list"
        items={@machines}
        card_fields={
          fn m ->
            [
              %{label: gettext("Code"), value: m.code || "—"},
              %{label: gettext("Types"), value: type_names(m)},
              %{
                label: gettext("Location"),
                value: Machines.location_label(m, locale: @locale) || "—"
              },
              %{label: gettext("Status"), value: status_label(m.status)}
            ]
          end
        }
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Code")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Manufacturer")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Types")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Location")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">
              {gettext("Actions")}
            </.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={machine <- @machines}>
            <.table_default_cell>
              <.link navigate={Paths.machine_edit(machine.uuid)} class="link link-hover font-medium">
                {machine.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">
              {machine.code || "—"}
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">
              {machine.manufacturer || "—"}
            </.table_default_cell>
            <.table_default_cell>
              <div :if={machine.machine_types != []} class="flex flex-wrap gap-1">
                <span :for={t <- machine.machine_types} class="badge badge-sm badge-outline">
                  {t.name}
                </span>
              </div>
              <span :if={machine.machine_types == []} class="text-base-content/40">—</span>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">
              {Machines.location_label(machine, locale: @locale) || "—"}
            </.table_default_cell>
            <.table_default_cell>
              <span class={["badge badge-sm", status_badge_class(machine.status)]}>
                {status_label(machine.status)}
              </span>
            </.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="dropdown" id={"machine-menu-#{machine.uuid}"}>
                <.table_row_menu_link
                  navigate={Paths.machine_edit(machine.uuid)}
                  icon="hero-pencil"
                  label={gettext("Edit")}
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="show_delete_confirm"
                  phx-value-uuid={machine.uuid}
                  phx-value-type="machine"
                  icon="hero-trash"
                  label={gettext("Delete")}
                  variant="error"
                />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={machine}>
          <.link navigate={Paths.machine_edit(machine.uuid)} class="font-medium text-sm link link-hover">
            {machine.name}
          </.link>
        </:card_header>
        <:card_actions :let={machine}>
          <.link navigate={Paths.machine_edit(machine.uuid)} class="btn btn-ghost btn-xs">
            {gettext("Edit")}
          </.link>
          <button
            phx-click="show_delete_confirm"
            phx-value-uuid={machine.uuid}
            phx-value-type="machine"
            class="btn btn-ghost btn-xs text-error"
          >
            {gettext("Delete")}
          </button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp types_table(assigns) do
    ~H"""
    <div :if={@machine_types == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{gettext("No machine types yet.")}</p>
      </div>
    </div>

    <div :if={@machine_types != []}>
      <.table_default
        variant="zebra"
        size="sm"
        toggleable={true}
        id="machine-types-list"
        items={@machine_types}
        card_fields={
          fn t ->
            [
              %{label: gettext("Description"), value: t.description || "—"},
              %{label: gettext("Status"), value: status_label(t.status)}
            ]
          end
        }
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Description")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">
              {gettext("Actions")}
            </.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={t <- @machine_types}>
            <.table_default_cell>
              <.link navigate={Paths.type_edit(t.uuid)} class="link link-hover font-medium">
                {t.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">
              {t.description || "—"}
            </.table_default_cell>
            <.table_default_cell>
              <span class={["badge badge-sm", status_badge_class(t.status)]}>
                {status_label(t.status)}
              </span>
            </.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="dropdown" id={"type-menu-#{t.uuid}"}>
                <.table_row_menu_link
                  navigate={Paths.type_edit(t.uuid)}
                  icon="hero-pencil"
                  label={gettext("Edit")}
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="show_delete_confirm"
                  phx-value-uuid={t.uuid}
                  phx-value-type="machine_type"
                  icon="hero-trash"
                  label={gettext("Delete")}
                  variant="error"
                />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={t}>
          <.link navigate={Paths.type_edit(t.uuid)} class="font-medium text-sm link link-hover">
            {t.name}
          </.link>
        </:card_header>
        <:card_actions :let={t}>
          <.link navigate={Paths.type_edit(t.uuid)} class="btn btn-ghost btn-xs">
            {gettext("Edit")}
          </.link>
          <button
            phx-click="show_delete_confirm"
            phx-value-uuid={t.uuid}
            phx-value-type="machine_type"
            class="btn btn-ghost btn-xs text-error"
          >
            {gettext("Delete")}
          </button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp type_names(%{machine_types: types}) when is_list(types) and types != [] do
    Enum.map_join(types, ", ", & &1.name)
  end

  defp type_names(_), do: "—"

  defp status_label("active"), do: gettext("Active")
  defp status_label("inactive"), do: gettext("Inactive")
  defp status_label("maintenance"), do: gettext("Maintenance")
  defp status_label("repair"), do: gettext("Repair")
  defp status_label("mothballed"), do: gettext("Mothballed")
  defp status_label("decommissioned"), do: gettext("Decommissioned")
  defp status_label(other), do: other

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("maintenance"), do: "badge-warning"
  # Distinct from "maintenance" (badge-warning) — a machine actively down
  # for repair reads as more urgent than a scheduled maintenance window.
  defp status_badge_class("repair"), do: "badge-error"
  defp status_badge_class("mothballed"), do: "badge-ghost badge-outline"
  defp status_badge_class("decommissioned"), do: "badge-error badge-outline"
  defp status_badge_class(_), do: "badge-ghost"
end
