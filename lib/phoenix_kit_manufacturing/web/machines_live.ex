defmodule PhoenixKitManufacturing.Web.MachinesLive do
  @moduledoc """
  Landing page for the Machines reference book.

  Handles four actions, dispatched by `live_action`:

    * `:index` — list of machines, backed by
      `PhoenixKitManufacturing.ColumnConfig.Machines` for configurable
      columns, per-column filters, sorting, and a saved view (persisted via
      `PhoenixKitManufacturing.ViewConfigs`). See `Web.ColumnManagement`.
    * `:types` / `:operations` / `:defect_reasons` — redirect-only, as of
      the entities migration (`dev_docs/ENTITIES_MIGRATION_SPEC.md`).
      `machine_type`/`operation`/`defect_reason` CRUD now lives on the
      generic entities admin UI, so `load_data/2` immediately
      `push_navigate`s to the matching `/admin/entities/:slug/data` page
      (`Paths.types/0` / `.operations/0` / `.defect_reasons/0`) instead of
      rendering a list of its own — see `load_data/2`'s redirect clause.

  Admin-chrome pattern: self-wrapping render with `LayoutWrapper.app_layout`
  so the active subtab's name/description land in the global admin header
  (`page_title`/`page_subtitle`, see the `:self_wrapped_layout` on_mount and
  `tab_title/1` / `tab_subtitle/1`) instead of an in-page header. The
  Machines / Types / Operations / Defect Reasons switcher is a local
  `tabs tabs-border` bar rendered under that header — same look as
  `PhoenixKitWarehouse.Web.Components.WarehouseHeader` — in addition to
  (not instead of) the PhoenixKit admin sidebar's own subtab nav
  (`:manufacturing_machines` / `:manufacturing_types` /
  `:manufacturing_operations` / `:manufacturing_defect_reasons`), same
  dual-nav shape every other module's parent/subtab pair uses.

  ## Filtering UI

  Unlike `PhoenixKitWarehouse`'s list pages, `:index` does not render a
  `FilterChips`-style pill widget per active filter — deliberately, to keep
  this wave's footprint small (`dev_docs/IMPLEMENTATION_PLAN.md` M17).
  Toggling a column's funnel icon in the Columns modal still reveals a
  plain labeled input for that column (driven by the very same
  `set_filter_value`/`clear_filter` events `Web.ColumnManagement` injects),
  but instead of per-chip pill styling with an individual ✕ button, a
  single "N filters active" indicator plus one "Reset" button clears every
  filter value at once.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  use PhoenixKitManufacturing.Web.ColumnManagement,
    column_config: PhoenixKitManufacturing.ColumnConfig.Machines,
    scope: "manufacturing_machines"

  require Logger

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.Events
  alias PhoenixKitManufacturing.ColumnConfig.Machines, as: MachineColumnConfig
  alias PhoenixKitManufacturing.{EntitiesRegistry, Errors, Machines, Paths}
  alias PhoenixKitManufacturing.Web.Components.ColumnModal

  # Opt out of PhoenixKit's auto admin-chrome layout so this view self-wraps
  # with `LayoutWrapper.app_layout` in render/1 — lets page_title/page_subtitle
  # vary per subtab (set in handle_params/3) instead of being fixed at mount.
  # Same pattern as PhoenixKitWarehouse.Web.StockLive.
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(_params, _session, socket) do
    # Same extraction as PhoenixKitWarehouse.Web.InventoriesLive's mount/3 —
    # used for :current_user_uuid (view-config persistence keying), not for
    # activity-log attribution (that's `actor_opts/1`, unrelated).
    scope = socket.assigns[:phoenix_kit_current_scope]
    current_user = scope && PhoenixKit.Users.Auth.Scope.user(scope)
    user_uuid = current_user && current_user.uuid

    if connected?(socket), do: subscribe_to_machine_type_changes()

    {:ok,
     assign(socket,
       page_title: gettext("Machines"),
       page_subtitle: tab_subtitle(:index),
       machines: [],
       confirm_delete: nil,
       locale: socket.assigns[:current_locale] || Gettext.get_locale(),
       current_user_uuid: user_uuid,
       search: "",
       sort_by: "name",
       sort_dir: :asc,
       # Safe defaults for column-management assigns — overwritten by
       # assign_column_state/2 in load_data/2 when live_action is :index.
       # Present in mount so `:if`-guarded template sections that reference
       # these never encounter a missing-assign error even if a connection
       # is re-established mid-session.
       selected_columns: [],
       active_filters: [],
       filter_values: %{},
       show_column_modal: false,
       temp_selected_columns: nil,
       temp_active_filters: nil
     )}
  end

  # Keeps an already-open :index page's `type_names` badges fresh when a
  # machine type is renamed, trashed, or reordered on
  # `/admin/entities/machine_type/data` — see the `handle_info/2` clauses
  # below. `EntitiesRegistry` invalidates its own ETS cache independently
  # on the same broadcast (see its moduledoc), so this only needs to
  # trigger a re-render, not resolve the new value itself. Scoped to the
  # `machine_type` entity specifically via `subscribe_to_entity_data/1`
  # (not `EntitiesRegistry`'s own broader `subscribe_to_all_data/0`) —
  # `:index` never shows operation/defect_reason data, so the wider topic
  # would only buy unrelated re-renders. Guarded the same way every other
  # DB read in this module is (see moduledoc "LiveViews wrap context reads
  # in rescue") — a host that hasn't run `mix phoenix_kit.update` yet (no
  # `phoenix_kit_entities` tables) must not crash the mount.
  defp subscribe_to_machine_type_changes do
    case Entities.get_entity_by_name("machine_type") do
      nil -> :ok
      entity -> Events.subscribe_to_entity_data(entity.uuid)
    end
  rescue
    error ->
      Logger.debug("Failed to subscribe to machine_type entity events: #{inspect(error)}")
      :ok
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action || :index

    socket =
      socket
      |> assign(:active_tab, action)
      |> assign(:page_title, tab_title(action))
      |> assign(:page_subtitle, tab_subtitle(action))
      |> assign(:confirm_delete, nil)
      |> load_data(action)

    {:noreply, socket}
  end

  # Re-runs the machines pipeline after a filter value change or a column
  # save (called by the `Web.ColumnManagement` macro); resets sort to the
  # fallback column if its own column was hidden. Mirrors
  # `PhoenixKitWarehouse.Web.InventoriesLive.__view_config_changed__/1` —
  # the fallback here is "name" (Machines' primary sortable identifier),
  # not inventories' "number".
  def __view_config_changed__(socket) do
    socket =
      if socket.assigns.sort_by in socket.assigns.selected_columns do
        socket
      else
        assign(socket, :sort_by, List.first(socket.assigns.selected_columns) || "name")
      end

    assign_machines(socket)
  end

  # Redirect-only live_actions (see moduledoc) never actually render, so
  # the exact string doesn't matter — but `handle_params/3` calls this for
  # every action, including those, before `load_data/2` gets a chance to
  # redirect. A single catch-all (rather than one clause per live_action)
  # avoids a `FunctionClauseError` on that call without pretending the
  # returned title is ever shown for anything but `:index`.
  defp tab_title(_action), do: gettext("Machines")

  defp tab_subtitle(_action), do: gettext("Production equipment reference book.")

  defp load_data(socket, :index) do
    socket
    |> PhoenixKitManufacturing.Web.ColumnManagement.assign_column_state(MachineColumnConfig)
    |> assign_machines()
  rescue
    error ->
      Logger.error("Failed to load machines: #{inspect(error)}")
      put_flash(socket, :error, gettext("Failed to load machines."))
  end

  # `machine_type`/`operation`/`defect_reason` CRUD moved to the generic
  # entities admin UI (see moduledoc) — these three subtabs no longer load
  # or render anything of their own, they just hand off to the matching
  # entities page.
  defp load_data(socket, action) when action in [:types, :operations, :defect_reasons] do
    push_navigate(socket, to: entities_redirect_path(action))
  end

  defp entities_redirect_path(:types), do: Paths.types()
  defp entities_redirect_path(:operations), do: Paths.operations()
  defp entities_redirect_path(:defect_reasons), do: Paths.defect_reasons()

  # ── Machines pipeline (search + column filters + sort) ───────────

  defp assign_machines(socket) do
    machines =
      Machines.list_machines()
      |> enrich_machines(socket.assigns.locale)
      |> apply_global_search(socket.assigns.search)
      |> apply_column_filters(socket.assigns.active_filters, socket.assigns.filter_values)
      |> apply_sort(socket.assigns.sort_by, socket.assigns.sort_dir)

    assign(socket, :machines, machines)
  end

  # Flattens `Machine` structs into the enriched map shape
  # `ColumnConfig.Machines` operates on (see its moduledoc). Keeps `:data`
  # so `machine_thumbnail/1` (which reads `data["featured_image_uuid"]`,
  # see `PhoenixKitManufacturing.Attachments`) works unchanged against
  # either a raw `%Machine{}` or this flat map.
  defp enrich_machines(machines, locale) do
    location_by_uuid = location_labels(machines, locale)
    type_uuids_by_machine = Machines.linked_type_uuids_by_machine(Enum.map(machines, & &1.uuid))

    Enum.map(machines, fn m ->
      # `EntitiesRegistry.label/3` resolves "Unknown" for a type_uuid it
      # doesn't recognize (trashed/hard-removed out from under this soft
      # reference) rather than dropping it — a dangling link stays visible
      # instead of silently vanishing from the badge list, the graceful-
      # degradation behavior `dev_docs/ENTITIES_MIGRATION_SPEC.md` §5
      # calls for.
      type_names =
        type_uuids_by_machine
        |> Map.get(m.uuid, [])
        |> Enum.map(&EntitiesRegistry.label(&1, :machine_type, locale))
        |> Enum.sort()

      %{
        uuid: m.uuid,
        name: m.name,
        code: m.code,
        status: m.status,
        status_label: status_label(m.status),
        location: Map.get(location_by_uuid, m.uuid),
        types_csv: Enum.join(type_names, ", "),
        type_names: type_names,
        manufacturer: m.manufacturer,
        model: m.model,
        manufacture_year: m.manufacture_year,
        commissioned_on: m.commissioned_on,
        warranty_until: m.warranty_until,
        to_next_on: m.to_next_on,
        data: m.data
      }
    end)
  end

  # Batch-resolves location labels, deduping identical location_uuid/
  # space_uuid/location_note combinations across the list before calling
  # into phoenix_kit_locations. `Machines.location_label/2` makes 1-2 soft
  # cross-module DB round trips per call, and a shop floor commonly parks
  # many machines in the same room/rack, so resolving each distinct
  # combination once — not once per row — avoids redundant queries. See
  # dev_docs/IMPLEMENTATION_PLAN.md's M15/M17 review note on batching
  # `location_label`.
  defp location_labels(machines, locale) do
    cache =
      Enum.reduce(machines, %{}, fn machine, acc ->
        key = location_key(machine)

        if Map.has_key?(acc, key) do
          acc
        else
          Map.put(acc, key, Machines.location_label(machine, locale: locale))
        end
      end)

    Map.new(machines, &{&1.uuid, Map.get(cache, location_key(&1))})
  end

  defp location_key(machine),
    do: {machine.location_uuid, machine.space_uuid, machine.location_note}

  defp apply_global_search(entries, ""), do: entries

  defp apply_global_search(entries, query) do
    q = String.downcase(query)

    Enum.filter(entries, fn e ->
      Enum.any?([e.name, e.code, e.manufacturer, e.model], fn field ->
        field && String.contains?(String.downcase(field), q)
      end)
    end)
  end

  defp apply_column_filters(entries, active_filters, filter_values) do
    meta_map = MachineColumnConfig.column_metadata_map()

    Enum.reduce(active_filters, entries, fn id, acc ->
      meta = Map.get(meta_map, id)
      value = Map.get(filter_values, id)

      cond do
        is_nil(meta) -> acc
        is_nil(value) -> acc
        true -> meta.filter_apply.(acc, value)
      end
    end)
  end

  defp apply_sort(entries, by, dir) do
    case Map.get(MachineColumnConfig.column_metadata_map(), by) do
      %{sort_key: key_fn} when is_function(key_fn, 1) -> Enum.sort_by(entries, key_fn, dir)
      _ -> entries
    end
  end

  defp parse_sort_by(value) when is_binary(value) do
    case Map.get(MachineColumnConfig.column_metadata_map(), value) do
      %{sortable?: true} -> value
      _ -> "name"
    end
  end

  defp parse_sort_by(value) when is_atom(value), do: parse_sort_by(Atom.to_string(value))
  defp parse_sort_by(_), do: "name"

  defp flip_dir(:asc), do: :desc
  defp flip_dir(_), do: :asc

  defp default_dir(column_id) do
    case Map.get(MachineColumnConfig.column_metadata_map(), column_id) do
      %{default_dir: dir} -> dir
      _ -> :asc
    end
  end

  defp sortable_visible(selected_columns) do
    meta_map = MachineColumnConfig.column_metadata_map()

    selected_columns
    |> Enum.map(&Map.get(meta_map, &1))
    |> Enum.filter(&(&1 && &1.sortable?))
  end

  # Counts only filters that currently hold a value (i.e. are actually
  # narrowing `@machines`), not every column merely toggled filterable —
  # a toggled-but-empty filter input doesn't change the result set.
  defp count_active_filters(active_filters, filter_values) do
    Enum.count(active_filters, &filter_value_present?(Map.get(filter_values, &1)))
  end

  defp filter_value_present?(nil), do: false
  defp filter_value_present?(""), do: false

  defp filter_value_present?(%{} = value),
    do: Enum.any?(value, fn {_k, v} -> v not in [nil, ""] end)

  defp filter_value_present?(_value), do: true

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(:search, search) |> assign_machines()}
  end

  def handle_event("set_sort", %{"sort_by" => by}, socket) do
    {:noreply, socket |> assign(:sort_by, parse_sort_by(by)) |> assign_machines()}
  end

  def handle_event("toggle_sort", %{"by" => by}, socket) do
    by_id = parse_sort_by(by)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == by_id,
        do: {by_id, flip_dir(socket.assigns.sort_dir)},
        else: {by_id, default_dir(by_id)}

    {:noreply,
     socket |> assign(:sort_by, sort_by) |> assign(:sort_dir, sort_dir) |> assign_machines()}
  end

  def handle_event("flip_sort_dir", _params, socket) do
    {:noreply,
     socket |> assign(:sort_dir, flip_dir(socket.assigns.sort_dir)) |> assign_machines()}
  end

  # Bulk-clears every filter value at once — the "Reset" button that
  # substitutes for FilterChips' per-chip ✕ buttons (see moduledoc).
  # Leaves `active_filters` (which columns show a filter input) untouched,
  # only the entered values.
  def handle_event("clear_all_filters", _params, socket) do
    {:noreply, socket |> assign(:filter_values, %{}) |> __view_config_changed__()}
  end

  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("delete_machine", _params, socket) do
    case socket.assigns.confirm_delete do
      {"machine", uuid} -> do_delete_item(socket, :machine, uuid)
      _ -> {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  # Machine-type data changed on the entities admin UI — refresh
  # `:machines` so its `type_names` badges (resolved via
  # `EntitiesRegistry.label/3` in `enrich_machines/2`) don't keep showing a
  # stale/trashed title. Comes before the catch-all clause below — Elixir
  # tries `handle_info/2` clauses in source order. See
  # `subscribe_to_machine_type_changes/0` for the subscription itself and
  # `PhoenixKitEntities.Events` for the message shapes matched here.
  def handle_info({event, _entity_uuid, _data_uuid}, socket)
      when event in [:data_created, :data_updated, :data_deleted] do
    {:noreply, assign_machines(socket)}
  end

  def handle_info({:data_reordered, _entity_uuid}, socket) do
    {:noreply, assign_machines(socket)}
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

  defp delete_for_kind(:machine, record, socket),
    do: Machines.delete_machine(record, actor_opts(socket))

  defp deleted_message(:machine), do: gettext("Machine deleted.")

  defp not_found_atom(:machine), do: :machine_not_found

  defp delete_failed_atom(:machine), do: :machine_delete_failed

  defp reload_action(:machine), do: :index

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
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={@page_subtitle}
      current_path={assigns[:url_path] || assigns[:current_path] || Paths.machines()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-6 gap-6">
        <.machines_tab_bar active={@active_tab} />

        <div :if={@active_tab == :index}>
          <.table_default
            id="machines-list"
            variant="zebra"
            size="sm"
            toggleable
            items={@machines}
            card_fields={
              fn entry ->
                meta_map = MachineColumnConfig.column_metadata_map()

                Enum.map(@selected_columns, fn col ->
                  %{label: column_label(meta_map, col), value: render_card_value(col, entry)}
                end)
              end
            }
          >
            <:toolbar_title>
              <div class="flex flex-col gap-2 min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <form id="machines-search" phx-change="search" class="contents">
                    <label class="input input-sm w-full sm:w-64">
                      <.icon name="hero-magnifying-glass" class="h-4 w-4 opacity-50" />
                      <input
                        type="search"
                        name="search"
                        value={@search}
                        placeholder={gettext("Search...")}
                        class="grow"
                        phx-debounce="300"
                      />
                    </label>
                  </form>

                  <div
                    :if={@active_filters != []}
                    class="flex items-center gap-2 text-xs text-base-content/60"
                  >
                    <span>
                      {ngettext(
                        "%{count} filter active",
                        "%{count} filters active",
                        count_active_filters(@active_filters, @filter_values)
                      )}
                    </span>
                    <button type="button" phx-click="clear_all_filters" class="btn btn-ghost btn-xs">
                      {gettext("Reset")}
                    </button>
                  </div>
                </div>

                <div :if={@active_filters != []} class="flex flex-wrap items-center gap-3">
                  <%= for id <- @active_filters,
                            meta = Map.get(MachineColumnConfig.column_metadata_map(), id),
                            meta do %>
                    <div class="flex items-center gap-1">
                      <span class="text-xs text-base-content/50 whitespace-nowrap">
                        {meta.label.()}:
                      </span>
                      <.filter_input meta={meta} value={Map.get(@filter_values, id)} entries={@machines} />
                    </div>
                  <% end %>
                </div>
              </div>
            </:toolbar_title>

            <:toolbar_actions>
              <.link navigate={Paths.machine_new()} class="btn btn-primary btn-sm">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New Machine")}
              </.link>

              <span class="text-sm text-base-content/70 whitespace-nowrap">{gettext("Sort by:")}</span>
              <form id="machines-sort" phx-change="set_sort" class="join">
                <select name="sort_by" class="select select-sm join-item">
                  <option
                    :for={meta <- sortable_visible(@selected_columns)}
                    value={meta.id}
                    selected={@sort_by == meta.id}
                  >
                    {meta.label.()}
                  </option>
                </select>
                <button
                  type="button"
                  phx-click="flip_sort_dir"
                  class="btn btn-sm btn-ghost join-item"
                  title={
                    if @sort_dir == :asc,
                      do: gettext("Ascending"),
                      else: gettext("Descending")
                  }
                >
                  <.icon
                    name={if @sort_dir == :asc, do: "hero-chevron-up", else: "hero-chevron-down"}
                    class="w-4 h-4"
                  />
                </button>
              </form>

              <button
                type="button"
                class="btn btn-outline btn-sm"
                phx-click="show_column_modal"
                title={gettext("Customize columns")}
              >
                <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
                <span class="hidden sm:inline">{gettext("Columns")}</span>
              </button>
            </:toolbar_actions>

            <:card_header :let={entry}>
              <div class="flex items-center gap-2 min-w-0">
                <.machine_thumbnail machine={entry} />
                <.link
                  navigate={Paths.machine_edit(entry.uuid)}
                  class="font-medium text-sm link link-hover truncate min-w-0"
                >
                  {entry.name}
                </.link>
              </div>
            </:card_header>
            <:card_actions :let={entry}>
              <.link navigate={Paths.machine_edit(entry.uuid)} class="btn btn-ghost btn-xs">
                {gettext("Edit")}
              </.link>
              <button
                phx-click="show_delete_confirm"
                phx-value-uuid={entry.uuid}
                phx-value-type="machine"
                class="btn btn-ghost btn-xs text-error"
              >
                {gettext("Delete")}
              </button>
            </:card_actions>

            <.table_default_header>
              <.table_default_row hover={false}>
                <% meta_map = MachineColumnConfig.column_metadata_map() %>
                <%= for col <- @selected_columns, meta = Map.get(meta_map, col), meta do %>
                  <.table_default_header_cell class={if meta.align == :right, do: "text-right"}>
                    <%= if meta.sortable? do %>
                      <.sort_header
                        by={meta.id}
                        label={meta.label.()}
                        sort_by={@sort_by}
                        sort_dir={@sort_dir}
                        align={meta.align}
                      />
                    <% else %>
                      {meta.label.()}
                    <% end %>
                  </.table_default_header_cell>
                <% end %>
                <.table_default_header_cell class="text-right whitespace-nowrap">
                  {gettext("Actions")}
                </.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>

            <.table_default_body>
              <%= if @machines == [] do %>
                <.table_default_row hover={false}>
                  <.table_default_cell
                    colspan={length(@selected_columns) + 1}
                    class="text-center py-10 text-base-content/50"
                  >
                    <.icon name="hero-cog-6-tooth" class="h-10 w-10 mx-auto mb-2 opacity-50" />
                    <div class="text-sm font-medium">{gettext("No machines yet.")}</div>
                  </.table_default_cell>
                </.table_default_row>
              <% end %>
              <%= for entry <- @machines do %>
                <.table_default_row>
                  <% meta_map = MachineColumnConfig.column_metadata_map() %>
                  <%= for col <- @selected_columns, meta = Map.get(meta_map, col), meta do %>
                    <.table_default_cell class={cell_class(meta)}>
                      {render_cell(col, entry)}
                    </.table_default_cell>
                  <% end %>
                  <.table_default_cell class="text-right whitespace-nowrap">
                    <.table_row_menu mode="dropdown" id={"machine-menu-#{entry.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.machine_edit(entry.uuid)}
                        icon="hero-pencil"
                        label={gettext("Edit")}
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="show_delete_confirm"
                        phx-value-uuid={entry.uuid}
                        phx-value-type="machine"
                        icon="hero-trash"
                        label={gettext("Delete")}
                        variant="error"
                      />
                    </.table_row_menu>
                  </.table_default_cell>
                </.table_default_row>
              <% end %>
            </.table_default_body>
          </.table_default>

          <ColumnModal.column_modal
            show={@show_column_modal}
            column_config={MachineColumnConfig}
            selected={@selected_columns}
            active_filters={@active_filters}
            temp_selected={@temp_selected_columns}
            temp_active_filters={@temp_active_filters}
          />
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
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  attr(:active, :atom, required: true)

  # Local subtab switcher, styled/structured like
  # `PhoenixKitWarehouse.Web.Components.WarehouseHeader` — a `tabs
  # tabs-border` bar under the self-wrapped global header. `navigate` (not
  # `patch`) because each subtab is a distinct route (see moduledoc); the
  # active tab id matches `@active_tab`/`live_action` exactly.
  defp machines_tab_bar(assigns) do
    ~H"""
    <div role="tablist" class="tabs tabs-border">
      <.link
        role="tab"
        navigate={Paths.machines()}
        class={["tab", @active == :index && "tab-active"]}
      >
        {gettext("Machines")}
      </.link>
      <.link role="tab" navigate={Paths.types()} class={["tab", @active == :types && "tab-active"]}>
        {gettext("Types")}
      </.link>
      <.link
        role="tab"
        navigate={Paths.operations()}
        class={["tab", @active == :operations && "tab-active"]}
      >
        {gettext("Operations")}
      </.link>
      <.link
        role="tab"
        navigate={Paths.defect_reasons()}
        class={["tab", @active == :defect_reasons && "tab-active"]}
      >
        {gettext("Defect Reasons")}
      </.link>
    </div>
    """
  end

  attr(:by, :string, required: true)
  attr(:label, :string, required: true)
  attr(:sort_by, :string, required: true)
  attr(:sort_dir, :atom, required: true)
  attr(:align, :atom, default: :left)

  defp sort_header(assigns) do
    assigns = assign(assigns, :active?, assigns.sort_by == assigns.by)

    ~H"""
    <button
      type="button"
      phx-click="toggle_sort"
      phx-value-by={@by}
      class={[
        "inline-flex items-center gap-1 cursor-pointer select-none",
        @align == :right && "justify-end w-full"
      ]}
    >
      <span>{@label}</span>
      <.icon
        :if={@active?}
        name={if @sort_dir == :asc, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
        class="w-3.5 h-3.5"
      />
    </button>
    """
  end

  # Plain (non-chip) per-column filter input, dispatched on `filter_type`.
  # Functionally equivalent to PhoenixKitWarehouse's
  # `FilterChips.input_for_type/1` (same event contract: a
  # `phx-change="set_filter_value"` form with a hidden `column_id`), minus
  # the pill/icon/individual-clear-button chrome — see moduledoc.
  attr(:meta, :map, required: true)
  attr(:value, :any, default: nil)
  attr(:entries, :list, default: [])

  defp filter_input(%{meta: %{filter_type: :text}} = assigns) do
    ~H"""
    <form phx-change="set_filter_value" class="contents">
      <input type="hidden" name="column_id" value={@meta.id} />
      <input
        type="search"
        name="value"
        value={@value || ""}
        placeholder={gettext("Contains...")}
        class="input input-xs input-bordered w-32"
        phx-debounce="300"
      />
    </form>
    """
  end

  defp filter_input(%{meta: %{filter_type: :enum}} = assigns) do
    options =
      case Map.get(assigns.meta, :filter_options) do
        fun when is_function(fun, 1) -> fun.(assigns.entries)
        _ -> []
      end

    assigns = assign(assigns, :options, options)

    ~H"""
    <form phx-change="set_filter_value" class="contents">
      <input type="hidden" name="column_id" value={@meta.id} />
      <select name="value" class="select select-xs select-bordered">
        <option value="" selected={@value in [nil, ""]}>{gettext("Any")}</option>
        <option
          :for={{val, label} <- @options}
          value={val}
          selected={to_string(@value) == to_string(val)}
        >
          {label}
        </option>
      </select>
    </form>
    """
  end

  defp filter_input(%{meta: %{filter_type: :numeric_range}} = assigns) do
    {min, max} = range_values(assigns.value, "min", "max")
    assigns = assigns |> assign(:min, min) |> assign(:max, max)

    ~H"""
    <form phx-change="set_filter_value" class="contents">
      <input type="hidden" name="column_id" value={@meta.id} />
      <input
        type="number"
        step="any"
        name="value[min]"
        value={@min}
        placeholder={gettext("Min")}
        class="input input-xs input-bordered w-20"
        phx-debounce="300"
      />
      <span class="text-xs text-base-content/40">–</span>
      <input
        type="number"
        step="any"
        name="value[max]"
        value={@max}
        placeholder={gettext("Max")}
        class="input input-xs input-bordered w-20"
        phx-debounce="300"
      />
    </form>
    """
  end

  defp filter_input(%{meta: %{filter_type: :date_range}} = assigns) do
    {from, to} = range_values(assigns.value, "from", "to")
    assigns = assigns |> assign(:from, from) |> assign(:to, to)

    ~H"""
    <form phx-change="set_filter_value" class="contents">
      <input type="hidden" name="column_id" value={@meta.id} />
      <input type="date" name="value[from]" value={@from} class="input input-xs input-bordered w-36" />
      <span class="text-xs text-base-content/40">–</span>
      <input type="date" name="value[to]" value={@to} class="input input-xs input-bordered w-36" />
    </form>
    """
  end

  defp range_values(%{} = value, key_a, key_b),
    do: {Map.get(value, key_a) || "", Map.get(value, key_b) || ""}

  defp range_values(_value, _key_a, _key_b), do: {"", ""}

  # ── Per-column rendering ──────────────────────────────────────────

  defp column_label(meta_map, col) do
    case Map.get(meta_map, col) do
      %{label: label_fn} -> label_fn.()
      _ -> col
    end
  end

  defp cell_class(%{align: :right}), do: "text-right text-sm"
  defp cell_class(_meta), do: "text-sm"

  defp render_cell("name", entry) do
    assigns = %{entry: entry}

    ~H"""
    <div class="flex items-center gap-2 min-w-0">
      <.machine_thumbnail machine={@entry} />
      <.link navigate={Paths.machine_edit(@entry.uuid)} class="link link-hover font-medium">
        {@entry.name}
      </.link>
    </div>
    """
  end

  defp render_cell("status", entry) do
    assigns = %{entry: entry}

    ~H"""
    <.status_badge status={@entry.status} label={@entry.status_label} />
    """
  end

  defp render_cell("types", entry) do
    assigns = %{entry: entry}

    ~H"""
    <.type_badges names={@entry.type_names} />
    """
  end

  defp render_cell("commissioned_on", entry), do: fmt_date(entry.commissioned_on)
  defp render_cell("warranty_until", entry), do: fmt_date(entry.warranty_until)
  defp render_cell("to_next_on", entry), do: fmt_date(entry.to_next_on)
  defp render_cell("manufacture_year", entry), do: emdash(entry.manufacture_year)
  defp render_cell("code", entry), do: emdash(entry.code)
  defp render_cell("manufacturer", entry), do: emdash(entry.manufacturer)
  defp render_cell("model", entry), do: emdash(entry.model)
  defp render_cell("location", entry), do: emdash(entry.location)
  defp render_cell(_col, _entry), do: "—"

  # Card values: plain text/markup (no row-overlay link — the card header
  # already links to the machine).
  defp render_card_value("name", entry), do: entry.name

  defp render_card_value("status", entry) do
    assigns = %{entry: entry}

    ~H"""
    <.status_badge status={@entry.status} label={@entry.status_label} />
    """
  end

  defp render_card_value("types", entry) do
    assigns = %{entry: entry}

    ~H"""
    <.type_badges names={@entry.type_names} />
    """
  end

  defp render_card_value("commissioned_on", entry), do: fmt_date(entry.commissioned_on)
  defp render_card_value("warranty_until", entry), do: fmt_date(entry.warranty_until)
  defp render_card_value("to_next_on", entry), do: fmt_date(entry.to_next_on)
  defp render_card_value("manufacture_year", entry), do: emdash(entry.manufacture_year)
  defp render_card_value("code", entry), do: emdash(entry.code)
  defp render_card_value("manufacturer", entry), do: emdash(entry.manufacturer)
  defp render_card_value("model", entry), do: emdash(entry.model)
  defp render_card_value("location", entry), do: emdash(entry.location)
  defp render_card_value(_col, _entry), do: "—"

  attr(:status, :string, required: true)
  attr(:label, :string, required: true)

  defp status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_badge_class(@status)]}>{@label}</span>
    """
  end

  attr(:names, :list, required: true)

  defp type_badges(assigns) do
    ~H"""
    <div :if={@names != []} class="flex flex-wrap gap-1">
      <span :for={name <- @names} class="badge badge-sm badge-outline">{name}</span>
    </div>
    <span :if={@names == []} class="text-base-content/40">—</span>
    """
  end

  defp fmt_date(nil), do: "—"
  defp fmt_date(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")

  defp emdash(nil), do: "—"
  defp emdash(""), do: "—"
  defp emdash(v), do: v

  # Resolves the Storage file backing a machine's featured image (set via
  # the Files section on MachineFormLive — stored at
  # `machine.data["featured_image_uuid"]`, see `PhoenixKitManufacturing.Attachments`).
  # Accepts anything carrying a `:data` map — the `%Machine{}` struct and
  # the flat maps produced by `enrich_machines/2` above, so this resolution
  # logic only needs writing once.
  defp featured_thumbnail_file(%{data: data}) when is_map(data) do
    with uuid when is_binary(uuid) and uuid != "" <- Map.get(data, "featured_image_uuid"),
         %Storage.File{} = file <- safe_get_file(uuid) do
      file
    else
      _ -> nil
    end
  end

  defp featured_thumbnail_file(_), do: nil

  defp safe_get_file(uuid) do
    Storage.get_file(uuid)
  rescue
    error ->
      Logger.warning("Failed to load Storage file #{uuid}: #{inspect(error)}")
      nil
  end

  # Small avatar-style thumbnail rendered next to a machine's name in the
  # table's first column and in the mobile card header. Falls back to a
  # placeholder icon when no featured image is set (or it fails to resolve).
  defp machine_thumbnail(assigns) do
    assigns = assign(assigns, :file, featured_thumbnail_file(assigns.machine))

    ~H"""
    <div class={["avatar shrink-0", @file == nil && "avatar-placeholder"]}>
      <div class={[
        "w-8 h-8 rounded-full",
        if(@file, do: "overflow-hidden", else: "bg-base-200 flex items-center justify-center")
      ]}>
        <img
          :if={@file}
          src={URLSigner.signed_url(@file.uuid, "thumbnail")}
          alt=""
          class="w-full h-full object-cover"
        />
        <.icon :if={@file == nil} name="hero-camera" class="w-4 h-4 text-base-content/40" />
      </div>
    </div>
    """
  end

  defp status_label("active"), do: gettext("Active")
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
