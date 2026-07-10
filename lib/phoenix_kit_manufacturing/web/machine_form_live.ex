defmodule PhoenixKitManufacturing.Web.MachineFormLive do
  @moduledoc """
  Create/edit form for machines.

  Machine fields (name, code, manufacturer…) are plain identifiers, so this
  form uses core inputs rather than the multilang translatable fields used
  for machine *types*. Type links are managed with a click-to-toggle picker
  held in a `MapSet` and synced to the join table after the machine saves.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea

  alias PhoenixKitManufacturing.{Errors, Machines, Paths}
  alias PhoenixKitManufacturing.Schemas.Machine

  @statuses ~w(active maintenance decommissioned)

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_machine(action, params) do
      {:not_found, uuid} ->
        Logger.info("Machine not found for edit: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:machine_not_found))
         |> push_navigate(to: Paths.machines())}

      {machine, changeset, linked_type_uuids} ->
        {:ok,
         socket
         |> assign(
           page_title: page_title(action, machine),
           action: action,
           machine: machine,
           all_types: safe_list_types(),
           linked_type_uuids: MapSet.new(linked_type_uuids)
         )
         |> assign_form(changeset)}
    end
  end

  defp load_machine(:new, _params) do
    m = %Machine{}
    {m, Machines.change_machine(m), []}
  end

  defp load_machine(:edit, params) do
    case Machines.get_machine(params["uuid"]) do
      nil -> {:not_found, params["uuid"]}
      m -> {m, Machines.change_machine(m), safe_linked_type_uuids(m)}
    end
  end

  defp safe_linked_type_uuids(machine) do
    Machines.linked_type_uuids(machine.uuid)
  rescue
    error ->
      Logger.error("Failed to load linked types for #{machine.uuid}: #{inspect(error)}")
      []
  end

  defp safe_list_types do
    Machines.list_machine_types(status: "active")
  rescue
    error ->
      Logger.error("Failed to load machine types: #{inspect(error)}")
      []
  end

  defp page_title(:new, _machine), do: gettext("New Machine")
  defp page_title(:edit, machine), do: gettext("Edit %{name}", name: machine.name)

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :machine))
  end

  @impl true
  def handle_event("validate", %{"machine" => params}, socket) do
    changeset =
      socket.assigns.machine
      |> Machines.change_machine(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("toggle_type", %{"uuid" => uuid}, socket) do
    linked = socket.assigns.linked_type_uuids

    linked =
      if MapSet.member?(linked, uuid),
        do: MapSet.delete(linked, uuid),
        else: MapSet.put(linked, uuid)

    {:noreply, assign(socket, :linked_type_uuids, linked)}
  end

  def handle_event("save", %{"machine" => params}, socket) do
    save_machine(socket, socket.assigns.action, params)
  end

  # Defensive catch-all for unmatched messages. Logs at :debug.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[MachineFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp save_machine(socket, :new, params) do
    case Machines.create_machine(params, actor_opts(socket)) do
      {:ok, machine} ->
        sync_types_and_redirect(socket, machine.uuid, gettext("Machine created."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_machine(socket, :edit, params) do
    case Machines.update_machine(socket.assigns.machine, params, actor_opts(socket)) do
      {:ok, machine} ->
        sync_types_and_redirect(socket, machine.uuid, gettext("Machine updated."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp sync_types_and_redirect(socket, machine_uuid, message) do
    type_uuids = MapSet.to_list(socket.assigns.linked_type_uuids)

    case Machines.sync_machine_types(machine_uuid, type_uuids, actor_opts(socket)) do
      {:ok, _sync_state} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: Paths.machines())}

      {:error, _} ->
        Logger.error("Failed to sync machine types for #{machine_uuid}")

        {:noreply,
         socket
         |> put_flash(:warning, Errors.message(:type_assignment_failed))
         |> push_navigate(to: Paths.machines())}
    end
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  defp status_options do
    Enum.map(@statuses, fn status -> {status_label(status), status} end)
  end

  defp status_label("active"), do: gettext("Active")
  defp status_label("maintenance"), do: gettext("Maintenance")
  defp status_label("decommissioned"), do: gettext("Decommissioned")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <.admin_page_header
        title={@page_title}
        subtitle={
          if @action == :new,
            do: gettext("Add a machine to the reference book."),
            else: gettext("Update machine details.")
        }
      />

      <div class="max-w-3xl mx-auto w-full">
        <.form for={@form} phx-change="validate" phx-submit="save">
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body flex flex-col gap-5">
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("e.g., CNC Mill #3")}
                required
              />

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:code]}
                  type="text"
                  label={gettext("Code")}
                  placeholder={gettext("Inventory number, e.g. M-001")}
                />
                <.input
                  field={@form[:manufacturer]}
                  type="text"
                  label={gettext("Manufacturer")}
                />
              </div>

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:serial_number]}
                  type="text"
                  label={gettext("Serial number")}
                />
                <.input
                  field={@form[:location_note]}
                  type="text"
                  label={gettext("Location")}
                  placeholder={gettext("Workshop / room / warehouse")}
                />
              </div>

              <.textarea
                field={@form[:description]}
                label={gettext("Description")}
                rows="3"
                placeholder={gettext("Notes about this machine...")}
              />

              <.select
                field={@form[:status]}
                label={gettext("Status")}
                options={status_options()}
                class="transition-colors focus-within:select-primary"
              />

              <div :if={@all_types != []} class="flex flex-col gap-3">
                <div class="divider my-0"></div>

                <div class="flex items-center gap-2">
                  <.icon name="hero-tag" class="w-5 h-5 text-base-content/70" />
                  <span class="font-medium">{gettext("Machine Types")}</span>
                </div>
                <p class="text-sm text-base-content/50 -mt-2">
                  {gettext("Click to toggle. A machine can have multiple types.")}
                </p>

                <div class="flex flex-wrap gap-2">
                  <label
                    :for={t <- @all_types}
                    class={[
                      "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                      if(MapSet.member?(@linked_type_uuids, t.uuid),
                        do: "badge-primary",
                        else: "badge-ghost hover:badge-outline"
                      )
                    ]}
                    phx-click="toggle_type"
                    phx-value-uuid={t.uuid}
                  >
                    <.icon
                      :if={MapSet.member?(@linked_type_uuids, t.uuid)}
                      name="hero-check"
                      class="h-3.5 w-3.5"
                    />
                    {t.name}
                  </label>
                </div>
              </div>

              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={Paths.machines()} class="btn btn-ghost">{gettext("Cancel")}</.link>
                <button
                  type="submit"
                  class="btn btn-primary phx-submit-loading:opacity-75"
                  phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
                >
                  {if @action == :new, do: gettext("Create Machine"), else: gettext("Save Changes")}
                </button>
              </div>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
