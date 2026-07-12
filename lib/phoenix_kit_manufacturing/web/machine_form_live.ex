defmodule PhoenixKitManufacturing.Web.MachineFormLive do
  @moduledoc """
  Create/edit form for machines.

  Machine fields (name, code, manufacturer…) are plain identifiers, so this
  form uses core inputs rather than the multilang translatable fields used
  for machine *types*. Type links are managed with a click-to-toggle picker
  held in a `MapSet` and synced to the join table after the machine saves.

  ## Admin chrome

  Self-wraps with `LayoutWrapper.app_layout` (`:self_wrapped_layout` on_mount
  below) instead of relying on PhoenixKit's automatic admin layout, so
  `page_title`/`page_subtitle` render in the global admin header rather than
  an in-page one — same pattern as `PhoenixKitManufacturing.Web.MachinesLive`.

  ## Tabs

  Once a machine exists, its card is split into in-page tabs (`tabs
  tabs-border`, `<.link patch={...}>`, same recipe as
  `PhoenixKitWarehouse.Web.InternalOrderFormLive`): General (passport,
  location, types, template fields), Operations, Files, Comments. Each tab
  has its own hidden CRUD route (`:operations`/`:files`/`:comments` in
  `PhoenixKitManufacturing.admin_tabs/0`, `visible: false` — same
  `hidden_crud_tabs` convention as the warehouse) so it's directly
  linkable/bookmarkable and survives a refresh, but never appears in the
  sidebar. Switching tabs is a `patch`, not a `navigate` — the LiveView
  process stays alive, so `handle_params/3` (not `mount/3`) does the actual
  per-action loading. `mount/3` only sets up tab-independent scaffolding
  (upload config, locale); `handle_params/3` loads the machine and, like
  `InternalOrderFormLive`'s `load_order_into_socket/3`, only rebuilds the
  *pending, unsaved* edit buffer (changeset, linked types/operations,
  Attachments scope state) the first time a given uuid is seen — a bare tab
  switch (`same_machine?` true) leaves it untouched, so toggling a type,
  picking a featured image, or setting an operation override survives
  navigating to another tab before hitting Save.

  A `:new` machine has no uuid yet and stays a single, tab-less page
  (General only, no tab bar) — Operations/Files/Comments only become
  reachable once the machine has been saved once, mirroring how
  `InternalOrderFormLive`'s `:new` never really renders past its own
  auto-create redirect.

  Save/Cancel live inside the shared `<.form>`, which wraps every tab
  *except* Comments — General, Operations, and Files all hold state that's
  still pending at save time (passport/types/template are changeset-backed;
  operation overrides and the featured-image pick are separate socket
  assigns synced at save, see below); Comments persists immediately through
  its own component and has nothing to save.

  ## Location (soft link, not a form field)

  `location_uuid`/`space_uuid` are picked via
  `PhoenixKitLocations.Web.Components.PlacePicker`, a `LiveComponent`
  rendered in its own card **outside** the main `<.form phx-change="validate">`
  — see the comment on that card in `render/1` for why. The picked uuids
  live in `@location_uuid`/`@space_uuid` (updated from the component's
  `{:place_picker_select, ...}` message) and are merged into the params in
  `save_machine/3`, not read off the form.

  ## Dynamic `metadata` fields

  Machine types can define a `field_template` — stored in the `machine_type`
  entity-data record's `metadata["field_template"]` (see `EntitiesRegistry`'s
  "Record shape" moduledoc section for why it lives in `metadata` rather
  than `data`); `Machines.merged_field_template/1` merges the templates of
  every linked, published type into `@merged_template`, rendered as extra
  inputs named `machine[metadata][KEY]` (raw `name=`, not `@form[:atom]` —
  `metadata` here is this *machine's* freeform value map, keyed by whatever
  the linked types define, not a fixed changeset field — a different
  `metadata` from the type record's own). Recomputed whenever the type
  selection changes. Each type badge carries a pencil icon-link to
  `Web.MachineTypeTemplateLive`, the hidden-route mini-editor for that
  type's own `field_template` — the generic entities admin UI has no widget
  for it (see that module's moduledoc for why).

  ## Operations

  Every published operation in the directory (see
  `PhoenixKitManufacturing.EntitiesRegistry`) can be linked to this machine,
  each link optionally overriding the operation's own
  `base_time_norm_seconds` for this machine specifically.
  `@operation_overrides` is a `%{operation_uuid => time_norm_seconds | nil}`
  map — its *key set* is exactly which operations are linked, the same
  shape `Machines.linked_operation_overrides/1` returns and
  `Machines.sync_machine_operations/3` takes as its desired "after" state,
  so the form assign doubles as the sync payload with no translation step
  (mirrors how `@linked_type_uuids` doubles as `sync_machine_types/3`'s
  payload). `toggle_operation` adds/removes a key (`nil` override — "use
  the operation's base norm" — until the user types one);
  `set_operation_override` (fired on the override input's `phx-blur`, not
  the enclosing `<.form>`'s `phx-change` — see that handler for why)
  updates an existing key's value, guarded with `Map.replace/3` so a stray
  blur event for a row the user has since unchecked can't silently
  re-link it. Both links are synced together in `sync_and_redirect/3`.

  ## Files & featured image

  Wired through `PhoenixKitManufacturing.Attachments`, the same
  folder-scoped pattern used by `PhoenixKitLocations.Attachments` (see
  that module's doc for the general mechanics) and rendered with
  `PhoenixKitManufacturing.Web.Components.FilesCard` on the Files tab
  (see "Tabs" above — only reachable once the machine has a uuid). This
  form only ever has one Attachments scope — the literal string
  `"machine"` — so every Attachments event handler below hardcodes it
  rather than reading `phx-value-scope` off the event params.
  `Attachments.maybe_rename_pending_folder_for/2` in `save_machine/3`'s
  `:new` clause is a leftover safety net from before the Files tab
  existed (a `:new` machine could upload before its first save, landing
  in a "pending" folder renamed post-save) — now a no-op in practice
  since `:new` never renders the Files tab, but left in place rather than
  torn out, since it's harmless and the fallback stays correct if that
  ever changes.

  One deliberate exception to "folder-scoped": the featured-image picker
  itself (the `MediaSelectorModal` in `render/1`) browses the *full*
  media library, not just this machine's folder — see the comment there
  for why. Everything else (attached-files upload, storage, detach) stays
  folder-scoped exactly as described above.

  ## Comments

  Only rendered on the Comments tab (`@active_tab == :comments`, which —
  see "Tabs" above — only exists once the machine has a `uuid`) and only
  when `PhoenixKitManufacturing.Comments.available?/0` is true. Like the
  Location card, this is rendered in its own card **outside** the main
  `<.form>` — `CommentsComponent` renders its own internal `<.form
  phx-target={@myself}>` for the composer, and nesting that inside this
  form's `<.form>` would produce invalid nested `<form>` elements. `use
  PhoenixKitComments.Embed` (below) forwards the rich-text composer's
  `{:leaf_changed, ...}` messages to the component — without it, posting
  a comment silently no-ops (see `PhoenixKitComments.Embed` moduledoc).
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext
  use PhoenixKitComments.Embed

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea
  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitManufacturing.Web.Components.FilesCard, only: [files_card_body: 1]

  alias PhoenixKitLocations.Web.Components.PlacePicker
  alias PhoenixKitManufacturing.{Attachments, Comments, EntitiesRegistry, Errors, Machines, Paths}
  alias PhoenixKitManufacturing.Schemas.Machine
  alias PhoenixKitManufacturing.Web.Components.CommentsPanel

  @statuses ~w(active maintenance repair mothballed decommissioned)

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header instead of an in-page one — same pattern as
  # `PhoenixKitManufacturing.Web.MachinesLive`.
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  # `mount/3` only sets up tab-independent scaffolding — upload config and
  # locale don't vary by which tab/action is active, so they belong here
  # rather than being redone on every `handle_params/3` (which runs on
  # every tab patch too, see the moduledoc's "Tabs" section). `machine`
  # starts `nil`; `handle_params/3` always runs before the first render
  # (for both disconnected and connected mounts) and populates it.
  @impl true
  def mount(_params, _session, socket) do
    locale = socket.assigns[:current_locale] || Gettext.get_locale()

    {:ok,
     socket
     |> assign(locale: locale, machine: nil, active_tab: :general)
     |> Attachments.init()
     |> Attachments.allow_attachment_upload()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new -> {:noreply, load_new(socket)}
      action -> handle_params_existing(socket, params["uuid"], action)
    end
  end

  defp load_new(socket) do
    machine = %Machine{}

    socket
    |> assign(
      page_title: page_title(:new, machine),
      action: :new,
      active_tab: :general,
      machine: machine,
      all_types: safe_list_types(socket.assigns.locale),
      linked_type_uuids: MapSet.new(),
      merged_template: [],
      all_operations: [],
      operation_overrides: %{},
      location_uuid: nil,
      space_uuid: nil,
      show_place_picker: true
    )
    |> assign_form(Machines.change_machine(machine))
    |> Attachments.mount(scope: "machine", resource: machine)
  end

  defp handle_params_existing(socket, uuid, live_action) do
    case Machines.get_machine(uuid) do
      nil ->
        Logger.info("Machine not found for edit: #{uuid}")

        {:noreply,
         socket
         |> put_flash(:error, Errors.message(:machine_not_found))
         |> push_navigate(to: Paths.machines())}

      machine ->
        {:noreply, load_existing(socket, machine, live_action)}
    end
  end

  # Refreshes the machine + tab on every landing/patch (cheap, read-only,
  # always safe), but only rebuilds the *pending, unsaved* edit buffer
  # (changeset, linked types/operations, Attachments scope state — see
  # `assign_edit_buffer/2`) the first time this uuid is seen. A same-machine
  # tab switch skips it, so in-progress edits survive navigating to another
  # tab before hitting Save — mirrors
  # `InternalOrderFormLive.load_order_into_socket/3`'s `same_order?` guard.
  defp load_existing(socket, machine, live_action) do
    uuid = machine.uuid
    same_machine? = match?(%{uuid: ^uuid}, socket.assigns[:machine])

    socket =
      assign(socket,
        machine: machine,
        action: :edit,
        active_tab: active_tab(live_action),
        page_title: page_title(:edit, machine)
      )

    if same_machine?, do: socket, else: assign_edit_buffer(socket, machine)
  end

  defp assign_edit_buffer(socket, machine) do
    locale = socket.assigns.locale
    linked_type_uuids = safe_linked_type_uuids(machine)

    socket
    |> assign(
      all_types: safe_list_types(locale),
      linked_type_uuids: MapSet.new(linked_type_uuids),
      merged_template: safe_merged_template(linked_type_uuids),
      all_operations: safe_list_operations(locale),
      operation_overrides: safe_operation_overrides(machine),
      location_uuid: machine.location_uuid,
      space_uuid: machine.space_uuid,
      show_place_picker: is_nil(machine.location_uuid) and is_nil(machine.space_uuid)
    )
    |> assign_form(Machines.change_machine(machine))
    |> Attachments.mount(scope: "machine", resource: machine)
  end

  # live_action -> tab id. `:edit` (General's own route) and any other
  # unrecognized action fall back to `:general` — only `:new` (handled
  # separately by `load_new/1`, never routed through here) has no tab bar.
  defp active_tab(:operations), do: :operations
  defp active_tab(:files), do: :files
  defp active_tab(:comments), do: :comments
  defp active_tab(_), do: :general

  defp safe_linked_type_uuids(machine) do
    Machines.linked_type_uuids(machine.uuid)
  rescue
    error ->
      Logger.error("Failed to load linked types for #{machine.uuid}: #{inspect(error)}")
      []
  end

  defp safe_list_types(locale) do
    Machines.list_machine_types(locale: locale, status: "published")
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

  defp safe_list_operations(locale) do
    EntitiesRegistry.list(:operation, locale, status: "published")
  rescue
    error ->
      Logger.error("Failed to load operations: #{inspect(error)}")
      []
  end

  # Only ever called from `assign_edit_buffer/2` — a `:new` machine has no
  # uuid yet, so `load_new/1` hardcodes `%{}` directly rather than routing
  # through here.
  defp safe_operation_overrides(machine) do
    Machines.linked_operation_overrides(machine.uuid)
  rescue
    error ->
      Logger.error("Failed to load linked operations for #{machine.uuid}: #{inspect(error)}")
      %{}
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

  def handle_event("toggle_operation", %{"uuid" => uuid}, socket) do
    overrides = socket.assigns.operation_overrides

    overrides =
      if Map.has_key?(overrides, uuid),
        do: Map.delete(overrides, uuid),
        else: Map.put(overrides, uuid, nil)

    {:noreply, assign(socket, :operation_overrides, overrides)}
  end

  # `phx-blur` on the override input itself (see `operation_row/1`), not the
  # enclosing `<.form>`'s `phx-change="validate"` — a plain input dispatches
  # its own `phx-*` bindings independently of the form's, so this never
  # touches `@changeset`/`@form` at all, only `@operation_overrides`
  # (mirrors `toggle_type`/`toggle_operation` living outside the changeset).
  # `Map.replace/3` is a no-op if `uuid` isn't a linked key any more — a
  # stray blur for a row the user has since unchecked shouldn't re-link it.
  def handle_event("set_operation_override", %{"uuid" => uuid, "value" => value}, socket) do
    {:noreply,
     update(socket, :operation_overrides, &Map.replace(&1, uuid, parse_override(value)))}
  end

  def handle_event("toggle_place_picker", _params, socket) do
    {:noreply, update(socket, :show_place_picker, &(!&1))}
  end

  def handle_event("save", %{"machine" => params}, socket) do
    save_machine(socket, socket.assigns.action, params)
  end

  # ── Attachments (featured image modal + inline files dropzone) ──
  # Scope is always the literal "machine" — this form has exactly one
  # Files/Attachments scope, so there's nothing to read off
  # phx-value-scope (contrast with multi-scope hosts like
  # PhoenixKitLocations, which forward the scope from each button).

  def handle_event("open_featured_image_picker", _params, socket),
    do: Attachments.open_featured_image_picker(socket, "machine")

  def handle_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  def handle_event("remove_file", %{"uuid" => uuid}, socket),
    do: Attachments.trash_file(socket, "machine", uuid)

  def handle_event("clear_featured_image", _params, socket),
    do: Attachments.clear_featured_image(socket, "machine")

  def handle_event("set_active_upload_scope", _params, socket),
    do: {:noreply, Attachments.set_active_upload_scope(socket, "machine")}

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

  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  # Defensive catch-all for unmatched messages. Logs at :debug.
  def handle_info(msg, socket) do
    Logger.debug("[MachineFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp save_machine(socket, :new, params) do
    case Machines.create_machine(prepare_params(params, socket), actor_opts(socket)) do
      {:ok, machine} ->
        # The Files card may have already created a "pending" folder (no
        # uuid to name it after yet, see `Attachments.folder_name_for/1`)
        # if the user uploaded a file before the first save. Rename it
        # to the machine's now-known deterministic folder name.
        machine_folder = Attachments.state(socket, "machine").folder_uuid
        _ = Attachments.maybe_rename_pending_folder_for(machine_folder, machine)

        sync_and_redirect(socket, machine.uuid, gettext("Machine created."))

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
        sync_and_redirect(socket, machine.uuid, gettext("Machine updated."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  # Merges the Location card's picked uuids (tracked in socket assigns, see
  # the moduledoc — never actual `<form>` fields), coerces boolean-typed
  # dynamic `metadata` fields from their submitted "true"/"on"/"false"
  # strings into real booleans (every other metadata value is stored
  # exactly as submitted, see `Machines.merged_field_template/1` doc), and
  # merges the Files card's folder/featured-image uuids into `params["data"]`.
  defp prepare_params(params, socket) do
    params
    |> Map.put("location_uuid", socket.assigns.location_uuid)
    |> Map.put("space_uuid", socket.assigns.space_uuid)
    |> Map.put(
      "metadata",
      coerce_metadata(Map.get(params, "metadata", %{}), socket.assigns.merged_template)
    )
    |> Attachments.inject_attachment_data(socket, "machine")
  end

  defp coerce_metadata(metadata, merged_template) do
    Enum.reduce(merged_template, metadata, fn row, acc ->
      if template_row(row, :type) == "boolean" do
        key = template_row(row, :key)
        coerce_boolean_field(acc, key, Map.get(metadata, key))
      else
        acc
      end
    end)
  end

  # Only coerce values that plausibly came from a checkbox. A field whose
  # template type was later switched to "boolean" may still hold an old
  # scalar (e.g. "500" from a former number field) — leave it untouched
  # instead of silently destroying it on the next unrelated save.
  defp coerce_boolean_field(acc, key, value)
       when value in [nil, "", "true", "on", "false", "off", true, false],
       do: Map.put(acc, key, value in ["true", "on", true])

  defp coerce_boolean_field(acc, _key, _value), do: acc

  # Blank/unparseable input ⇒ `nil` (falls back to the operation's own
  # `base_time_norm_seconds`, see `Machines.sync_machine_operations/3`),
  # same "empty means unset" convention as the rest of the passport's
  # optional numeric fields. Only a *full* integer match counts — partial
  # parses (stray trailing characters) are treated the same as blank rather
  # than silently truncated.
  defp parse_override(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  defp parse_override(_value), do: nil

  # Syncs both linked-resource sets (types, then operations) after a
  # successful create/update, then redirects to the machines list — one
  # combined flow rather than two chained sync-and-redirect steps, so a
  # save only ever does a single navigate. Each sync function returns its
  # own specific `:error` reason atom on failure
  # (`:type_assignment_failed` / `:operation_assignment_failed`), which
  # `Errors.message/1` already knows how to render, so the flash correctly
  # names whichever side actually failed without this function needing to
  # track that itself.
  defp sync_and_redirect(socket, machine_uuid, message) do
    opts = actor_opts(socket)
    type_uuids = MapSet.to_list(socket.assigns.linked_type_uuids)
    operation_overrides = socket.assigns.operation_overrides

    with {:ok, _} <- Machines.sync_machine_types(machine_uuid, type_uuids, opts),
         {:ok, _} <- Machines.sync_machine_operations(machine_uuid, operation_overrides, opts) do
      {:noreply,
       socket
       |> put_flash(:info, message)
       |> push_navigate(to: Paths.machines())}
    else
      {:error, reason} ->
        Logger.error("Failed to sync machine #{machine_uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:warning, Errors.message(reason))
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
  # `metadata["field_template"]` JSONB pipeline (see
  # `Machines.merged_field_template/1`) — tolerate both key styles anyway.
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
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={
        if @action == :new,
          do: gettext("Add a machine to the reference book."),
          else: gettext("Update machine details.")
      }
      current_path={assigns[:url_path] || assigns[:current_path] || Paths.machines()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-8 gap-6">
        <%!-- Featured-image picker — intentionally FULL-LIBRARY, not
             folder-scoped (`scope_folder_id: nil`; see
             `MediaSelectorModal`'s moduledoc for what that attr does).
             This is a deliberate deviation from the folder-scoped norm
             every sibling picker on this module and its warehouse/
             locations/catalogue counterparts uses: a machine's cover
             photo is very often already sitting in the library — a
             manufacturer stock shot of the same model, or a photo
             already picked for another machine — so restricting the
             browse to this one machine's own (usually near-empty)
             folder would hide exactly the images an admin wants and
             push them toward needless re-uploads/duplicates. The
             attached-files dropzone below (rendered via FilesCard,
             wired through `Attachments.handle_progress/3`) never goes
             through this modal at all, so it keeps uploading straight
             into the "machine" scope's own folder, unaffected. --%>
        <.live_component
          module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
          id="machine-form-media-selector"
          show={@show_media_selector}
          mode={@media_selection_mode}
          file_type_filter={@media_filter}
          selected_uuids={@media_selected_uuids}
          scope_folder_id={nil}
          phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
        />

        <div class="max-w-screen-2xl mx-auto w-full flex flex-col gap-6">
          <%!-- Tab navigation — only once the machine exists (has a uuid); a
               :new machine is a single-page General form with no tab bar at
               all yet (see the moduledoc's "Tabs" section). Operations is
               only offered when the directory has active operations to
               show — same "hide if empty" rule the section itself applied
               inline before the move. --%>
          <div :if={@machine.uuid} class="tabs tabs-border">
            <% files_count = length(Attachments.state(%{assigns: assigns}, "machine").files) %>
            <%
              comments_count =
                if Comments.available?(), do: Comments.count(:machine, @machine.uuid), else: 0
            %>
            <.link
              patch={Paths.machine_edit(@machine.uuid)}
              class={["tab", @active_tab == :general && "tab-active"]}
            >
              {gettext("General")}
            </.link>
            <.link
              :if={@all_operations != []}
              patch={Paths.machine_operations(@machine.uuid)}
              class={["tab", @active_tab == :operations && "tab-active"]}
            >
              {gettext("Operations")}
            </.link>
            <.link
              patch={Paths.machine_files(@machine.uuid)}
              class={["tab", @active_tab == :files && "tab-active"]}
            >
              {gettext("Files")}
              <span :if={files_count > 0} class="badge badge-xs badge-ghost">{files_count}</span>
            </.link>
            <.link
              :if={Comments.available?()}
              patch={Paths.machine_comments(@machine.uuid)}
              class={["tab", @active_tab == :comments && "tab-active"]}
            >
              {gettext("Comments")}
              <span :if={comments_count > 0} class="badge badge-xs badge-ghost">{comments_count}</span>
            </.link>
          </div>

          <%!-- Location — deliberately OUTSIDE the <.form> below. PlacePicker
               is a LiveComponent with its own search/tree inputs; nesting it
               inside <.form phx-change="validate"> would risk its native
               input/change events bubbling into the form's phx-change
               binding. The picked uuids live in socket assigns (see
               moduledoc) and never need to be real <form> fields. General
               tab only, like the rest of the passport. --%>
          <.location_card
            :if={@active_tab == :general}
            machine={@machine}
            location_uuid={@location_uuid}
            space_uuid={@space_uuid}
            locale={@locale}
            show_place_picker={@show_place_picker}
          />

          <%!-- Wraps every tab except Comments — General/Operations/Files all
               hold state that's still pending at save time (see moduledoc),
               so Save/Cancel live in one persistent footer below rather
               than being duplicated per tab. --%>
          <.form :if={@active_tab != :comments} for={@form} phx-change="validate" phx-submit="save">
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body flex flex-col gap-5">
                <%= if @active_tab == :general do %>
                  <.input
                    field={@form[:name]}
                    type="text"
                    label={gettext("Name")}
                    placeholder={gettext("e.g., CNC Mill #3")}
                    required
                  />

                  <%!-- Passport: identifying/spec fields. One grid (not several
                       paired 2-col ones) so the extra width freed up by the
                       form no longer being capped at max-w-3xl gets used —
                       up to 3 columns on large screens instead of fields
                       stretching edge-to-edge in a 2-col row. --%>
                  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
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
                    <.input field={@form[:model]} type="text" label={gettext("Model")} />
                    <.input
                      field={@form[:manufacture_year]}
                      type="number"
                      label={gettext("Manufacture year")}
                    />
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
                    <.input field={@form[:to_last_on]} type="date" label={gettext("Last maintenance")} />
                    <.input
                      field={@form[:to_interval_days]}
                      type="number"
                      label={gettext("Maintenance interval (days)")}
                    />
                    <.input
                      field={@form[:to_next_on]}
                      type="date"
                      label={gettext("Next maintenance due")}
                    />
                  </div>

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
                      <%!-- Badge + pencil link are siblings, not nested — the
                           pencil navigates to `Web.MachineTypeTemplateLive`
                           (a different route entirely), and nesting it inside
                           the badge's own phx-click="toggle_type" label would
                           let the click bubble up and toggle the type too. --%>
                      <div :for={t <- @all_types} class="inline-flex items-center gap-1">
                        <label
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
                        <.link
                          navigate={Paths.machine_type_template(t.uuid)}
                          class="btn btn-ghost btn-xs btn-circle"
                          title={gettext("Edit specification fields for %{name}", name: t.name)}
                        >
                          <.icon name="hero-pencil-square" class="h-3.5 w-3.5" />
                        </.link>
                      </div>
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
                <% end %>

                <%= if @active_tab == :operations do %>
                  <div :if={@all_operations != []} class="flex flex-col gap-3">
                    <div class="flex items-center gap-2">
                      <.icon name="hero-clock" class="w-5 h-5 text-base-content/70" />
                      <span class="font-medium">{gettext("Operations")}</span>
                    </div>
                    <p class="text-sm text-base-content/50 -mt-2">
                      {gettext(
                        "Toggle the operations this machine performs. Override the time norm for this machine, or leave it blank to use the operation's base norm."
                      )}
                    </p>

                    <.operation_row
                      :for={operation <- @all_operations}
                      operation={operation}
                      enabled?={Map.has_key?(@operation_overrides, operation.uuid)}
                      override={Map.get(@operation_overrides, operation.uuid)}
                    />
                  </div>
                <% end %>

                <%= if @active_tab == :files do %>
                  <.files_card_body
                    scope="machine"
                    state={Attachments.state(%{assigns: assigns}, "machine")}
                    uploads={@uploads}
                  />
                <% end %>

                <div class="divider my-0"></div>

                <div class="flex justify-end gap-3">
                  <.link navigate={Paths.machines()} class="btn btn-ghost">{gettext("Cancel")}</.link>
                  <button
                    type="submit"
                    class="btn btn-primary phx-submit-loading:opacity-75"
                    disabled={@uploads.attachment_files.entries != []}
                    phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
                  >
                    {cond do
                      @uploads.attachment_files.entries != [] -> gettext("Waiting for uploads...")
                      @action == :new -> gettext("Create Machine")
                      true -> gettext("Save Changes")
                    end}
                  </button>
                </div>
              </div>
            </div>
          </.form>

          <%!-- Comments — its own tab, deliberately OUTSIDE the <.form> above,
               same reason as the Location card: CommentsComponent renders
               its own internal <.form phx-target={@myself}> for the
               composer, and nesting a <form> inside a <form> is invalid
               HTML. Only reachable once the machine has a uuid (see the tab
               bar's :if above) and only when the comments module is
               installed and enabled. --%>
          <div :if={@active_tab == :comments and Comments.available?()} class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <CommentsPanel.panel
                kind={:machine}
                resource_uuid={@machine.uuid}
                current_user={assigns[:phoenix_kit_current_user]}
                title={gettext("Comments")}
              />
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
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

  # One row per active operation: a checkbox toggling the link
  # (`toggle_operation`, mirrors `toggle_type`) plus, only while linked, an
  # override input (`set_operation_override`). Neither control is bound to
  # `@form`/`@changeset` — both names below are synthetic, unbracketed
  # strings purely so the required `<.checkbox>`/`<.input>` `name=` attr
  # has *something* to render; the real state lives in
  # `@operation_overrides` (see moduledoc) and is only ever read from
  # `phx-value-uuid` + the dedicated event's own payload, never from a
  # `"machine"`-params submit.
  attr(:operation, :map, required: true)
  attr(:enabled?, :boolean, required: true)
  attr(:override, :integer, default: nil)

  defp operation_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <.checkbox
        name={"operation_toggle_#{@operation.uuid}"}
        checked={@enabled?}
        label={operation_label(@operation)}
        phx-click="toggle_operation"
        phx-value-uuid={@operation.uuid}
      />

      <.input
        :if={@enabled?}
        type="number"
        name={"operation_override_#{@operation.uuid}"}
        value={@override}
        placeholder={operation_override_placeholder(@operation)}
        wrapper_class="w-36"
        class="input-sm"
        phx-blur="set_operation_override"
        phx-value-uuid={@operation.uuid}
      />
    </div>
    """
  end

  defp operation_label(%{name: name, unit: unit, base_time_norm_seconds: base}) do
    hint = Enum.reject([blank_to_nil(unit), operation_base_hint(base)], &is_nil/1)
    if hint == [], do: name, else: "#{name} (#{Enum.join(hint, " · ")})"
  end

  defp operation_base_hint(nil), do: nil
  defp operation_base_hint(seconds), do: gettext("base %{seconds}s", seconds: seconds)

  defp operation_override_placeholder(%{base_time_norm_seconds: nil}),
    do: gettext("Base")

  defp operation_override_placeholder(%{base_time_norm_seconds: seconds}),
    do: gettext("Base: %{seconds}s", seconds: seconds)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
