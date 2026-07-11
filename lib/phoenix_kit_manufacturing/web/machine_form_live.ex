defmodule PhoenixKitManufacturing.Web.MachineFormLive do
  @moduledoc """
  Create/edit form for machines.

  Machine fields (name, code, manufacturer…) are plain identifiers, so this
  form uses core inputs rather than the multilang translatable fields used
  for machine *types*. Type links are managed with a click-to-toggle picker
  held in a `MapSet` and synced to the join table after the machine saves.

  ## Location (soft link, not a form field)

  `location_uuid`/`space_uuid` are picked via
  `PhoenixKitLocations.Web.Components.PlacePicker`, a `LiveComponent`
  rendered in its own card **outside** the main `<.form phx-change="validate">`
  — see the comment on that card in `render/1` for why. The picked uuids
  live in `@location_uuid`/`@space_uuid` (updated from the component's
  `{:place_picker_select, ...}` message) and are merged into the params in
  `save_machine/3`, not read off the form.

  ## Dynamic `metadata` fields

  Machine types can define a `field_template` (see `Schemas.MachineType`);
  `Machines.merged_field_template/1` merges the templates of every linked
  type into `@merged_template`, rendered as extra inputs named
  `machine[metadata][KEY]` (raw `name=`, not `@form[:atom]` — `metadata` is
  a freeform map keyed by whatever the linked types define, not a fixed
  changeset field). Recomputed whenever the type selection changes.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea
  import PhoenixKitWeb.Components.Core.Checkbox

  alias PhoenixKitLocations.Web.Components.PlacePicker
  alias PhoenixKitManufacturing.{Errors, Machines, Paths}
  alias PhoenixKitManufacturing.Schemas.Machine

  @statuses ~w(active maintenance repair mothballed decommissioned)

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action
    locale = socket.assigns[:current_locale] || Gettext.get_locale()

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
           linked_type_uuids: MapSet.new(linked_type_uuids),
           merged_template: safe_merged_template(linked_type_uuids),
           locale: locale,
           location_uuid: machine.location_uuid,
           space_uuid: machine.space_uuid,
           show_place_picker: is_nil(machine.location_uuid) and is_nil(machine.space_uuid)
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

  defp safe_merged_template(type_uuids) do
    Machines.merged_field_template(type_uuids)
  rescue
    error ->
      Logger.error("Failed to load merged field template: #{inspect(error)}")
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

    {:noreply,
     socket
     |> assign(:linked_type_uuids, linked)
     |> assign(:merged_template, safe_merged_template(MapSet.to_list(linked)))}
  end

  def handle_event("toggle_place_picker", _params, socket) do
    {:noreply, update(socket, :show_place_picker, &(!&1))}
  end

  def handle_event("save", %{"machine" => params}, socket) do
    save_machine(socket, socket.assigns.action, params)
  end

  # Handles a pick from the Location card's PlacePicker (id
  # "machine-place-picker") — must come before the catch-all clause below,
  # Elixir matches `handle_info/2` clauses in source order.
  @impl true
  def handle_info(
        {:place_picker_select, "machine-place-picker",
         %{location_uuid: location_uuid, space_uuid: space_uuid}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:location_uuid, location_uuid)
     |> assign(:space_uuid, space_uuid)
     |> assign(:show_place_picker, false)}
  end

  # Defensive catch-all for unmatched messages. Logs at :debug.
  def handle_info(msg, socket) do
    Logger.debug("[MachineFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp save_machine(socket, :new, params) do
    case Machines.create_machine(prepare_params(params, socket), actor_opts(socket)) do
      {:ok, machine} ->
        sync_types_and_redirect(socket, machine.uuid, gettext("Machine created."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_machine(socket, :edit, params) do
    case Machines.update_machine(
           socket.assigns.machine,
           prepare_params(params, socket),
           actor_opts(socket)
         ) do
      {:ok, machine} ->
        sync_types_and_redirect(socket, machine.uuid, gettext("Machine updated."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  # Merges the Location card's picked uuids (tracked in socket assigns, see
  # the moduledoc — never actual `<form>` fields) and coerces boolean-typed
  # dynamic `metadata` fields from their submitted "true"/"on"/"false"
  # strings into real booleans. Every other metadata value is stored
  # exactly as submitted (see `Machines.merged_field_template/1` doc).
  defp prepare_params(params, socket) do
    params
    |> Map.put("location_uuid", socket.assigns.location_uuid)
    |> Map.put("space_uuid", socket.assigns.space_uuid)
    |> Map.put(
      "metadata",
      coerce_metadata(Map.get(params, "metadata", %{}), socket.assigns.merged_template)
    )
  end

  defp coerce_metadata(metadata, merged_template) do
    Enum.reduce(merged_template, metadata, fn row, acc ->
      if template_row(row, :type) == "boolean" do
        key = template_row(row, :key)
        Map.put(acc, key, Map.get(metadata, key) in ["true", "on"])
      else
        acc
      end
    end)
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
  defp status_label("repair"), do: gettext("Repair")
  defp status_label("mothballed"), do: gettext("Mothballed")
  defp status_label("decommissioned"), do: gettext("Decommissioned")

  # Resolves the Location card's summary line off the *live* selection
  # (`@location_uuid`/`@space_uuid`), not the possibly-stale `@machine`
  # struct — otherwise picking a new place and collapsing the picker would
  # keep showing the old one until the page reloads after save.
  defp location_summary(machine, location_uuid, space_uuid, locale) do
    %{machine | location_uuid: location_uuid, space_uuid: space_uuid}
    |> Machines.location_label(locale: locale)
    |> case do
      nil -> gettext("Not set")
      label -> label
    end
  end

  # `field_template` rows are string-keyed once round-tripped through the
  # `field_template`/`merged_field_template` JSONB pipeline, same
  # atom/string tolerance as `Schemas.MachineType`'s own row accessor.
  defp template_row(row, atom_key) when is_map(row) do
    string_key = Atom.to_string(atom_key)

    cond do
      Map.has_key?(row, atom_key) -> Map.get(row, atom_key)
      Map.has_key?(row, string_key) -> Map.get(row, string_key)
      true -> nil
    end
  end

  defp dynamic_field_kind("number", _options), do: :number
  defp dynamic_field_kind("date", _options), do: :date
  defp dynamic_field_kind("boolean", _options), do: :boolean
  defp dynamic_field_kind("select", options) when is_list(options) and options != [], do: :select
  defp dynamic_field_kind(_type, _options), do: :text

  defp field_label(label, unit, required?) do
    unit_suffix = if unit in [nil, ""], do: "", else: " (#{unit})"
    required_suffix = if required?, do: " *", else: ""
    "#{label}#{unit_suffix}#{required_suffix}"
  end

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

      <div class="max-w-3xl mx-auto w-full flex flex-col gap-6">
        <%!-- Location — deliberately OUTSIDE the <.form> below. PlacePicker
             is a LiveComponent with its own search/tree inputs; nesting it
             inside <.form phx-change="validate"> would risk its native
             input/change events bubbling into the form's phx-change
             binding. The picked uuids live in socket assigns (see
             moduledoc) and never need to be real <form> fields. --%>
        <.location_card
          machine={@machine}
          location_uuid={@location_uuid}
          space_uuid={@space_uuid}
          locale={@locale}
          show_place_picker={@show_place_picker}
        />

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
                <.input field={@form[:model]} type="text" label={gettext("Model")} />
                <.input
                  field={@form[:manufacture_year]}
                  type="number"
                  label={gettext("Manufacture year")}
                />
              </div>

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:serial_number]}
                  type="text"
                  label={gettext("Serial number")}
                />
                <.input
                  :if={@action == :edit and @machine.location_note not in [nil, ""]}
                  field={@form[:location_note]}
                  type="text"
                  label={gettext("Location (legacy note)")}
                  placeholder={gettext("Workshop / room / warehouse")}
                />
              </div>

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:commissioned_on]}
                  type="date"
                  label={gettext("Commissioned on")}
                />
                <.input
                  field={@form[:warranty_until]}
                  type="date"
                  label={gettext("Warranty until")}
                />
              </div>

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input field={@form[:to_last_on]} type="date" label={gettext("Last maintenance")} />
                <.input
                  field={@form[:to_interval_days]}
                  type="number"
                  label={gettext("Maintenance interval (days)")}
                />
              </div>

              <.input
                field={@form[:to_next_on]}
                type="date"
                label={gettext("Next maintenance due")}
              />

              <.textarea
                field={@form[:description]}
                label={gettext("Description")}
                rows="3"
                placeholder={gettext("Notes about this machine...")}
              />

              <.textarea
                field={@form[:notes]}
                label={gettext("Internal notes")}
                rows="3"
                placeholder={gettext("Notes only visible to admins...")}
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

              <div :if={@merged_template != []} class="flex flex-col gap-3">
                <div class="divider my-0"></div>

                <div class="flex items-center gap-2">
                  <.icon name="hero-clipboard-document-list" class="w-5 h-5 text-base-content/70" />
                  <span class="font-medium">{gettext("Specifications")}</span>
                </div>
                <p class="text-sm text-base-content/50 -mt-2">
                  {gettext("Fields defined by the selected machine types.")}
                </p>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <.dynamic_metadata_field :for={row <- @merged_template} row={row} machine={@machine} />
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

  attr(:machine, Machine, required: true)
  attr(:location_uuid, :string, default: nil)
  attr(:space_uuid, :string, default: nil)
  attr(:locale, :string, default: nil)
  attr(:show_place_picker, :boolean, default: false)

  defp location_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body flex flex-col gap-3">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-2">
            <.icon name="hero-map-pin" class="w-5 h-5 text-base-content/70" />
            <span class="font-medium">{gettext("Location")}</span>
          </div>
          <button type="button" phx-click="toggle_place_picker" class="btn btn-ghost btn-xs">
            {if @show_place_picker, do: gettext("Hide"), else: gettext("Change")}
          </button>
        </div>

        <p class="text-sm text-base-content/70">
          {location_summary(@machine, @location_uuid, @space_uuid, @locale)}
        </p>

        <.live_component
          :if={@show_place_picker}
          module={PlacePicker}
          id="machine-place-picker"
          selected_space_uuid={@space_uuid}
          locale={@locale}
        />
      </div>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:machine, Machine, required: true)

  defp dynamic_metadata_field(assigns) do
    key = template_row(assigns.row, :key)
    type = template_row(assigns.row, :type)
    options = template_row(assigns.row, :options) || []
    metadata = assigns.machine.metadata || %{}

    assigns =
      assigns
      |> assign(:kind, dynamic_field_kind(type, options))
      |> assign(:field_name, "machine[metadata][#{key}]")
      |> assign(:raw_value, Map.get(metadata, key, ""))
      |> assign(:select_options, Enum.map(options, &{&1, &1}))
      |> assign(
        :label,
        field_label(
          template_row(assigns.row, :label),
          template_row(assigns.row, :unit),
          template_row(assigns.row, :required) == true
        )
      )

    ~H"""
    <.input :if={@kind == :text} type="text" name={@field_name} value={@raw_value} label={@label} />
    <.input :if={@kind == :number} type="number" name={@field_name} value={@raw_value} label={@label} />
    <.input :if={@kind == :date} type="date" name={@field_name} value={@raw_value} label={@label} />
    <.select
      :if={@kind == :select}
      name={@field_name}
      value={@raw_value}
      label={@label}
      options={@select_options}
      prompt="—"
    />
    <div :if={@kind == :boolean} class="flex items-end pb-2">
      <.checkbox name={@field_name} checked={@raw_value in [true, "true"]} label={@label} />
    </div>
    """
  end
end
