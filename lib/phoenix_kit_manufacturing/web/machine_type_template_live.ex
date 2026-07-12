defmodule PhoenixKitManufacturing.Web.MachineTypeTemplateLive do
  @moduledoc """
  Hidden-route mini-editor for a single `machine_type` entity's
  `field_template` — the list of dynamic `metadata` fields rendered on the
  machine form for machines linked to that type (see
  `Machines.merged_field_template/1`).

  ## Why this exists

  `machine_type` CRUD moved to the generic `phoenix_kit_entities` admin UI
  as part of the entities migration (`dev_docs/ENTITIES_MIGRATION_SPEC.md`),
  but that generic form only renders `fields_definition`-declared fields —
  `field_template` is deliberately *not* declared there (declaring it would
  expose a raw, unvalidated JSON-array editor with none of this module's
  row-level validation). It also isn't stored in `data` at all: the generic
  form's `Multilang.put_language_data/3` fully replaces the primary-language
  `data` block with only its declared fields on every save, which would
  silently drop an undeclared key living there. So `field_template` lives in
  `metadata["field_template"]` instead (see `EntitiesRegistry`'s "Record
  shape" moduledoc section), a column the generic entities form never
  touches — and this small standalone LiveView is the only way to edit it.

  ## Route

  `manufacturing/machine-types/:uuid/template`, `visible: false` in
  `PhoenixKitManufacturing.admin_tabs/0` — never appears in the sidebar.
  `:uuid` is the `machine_type` entity-data record's own uuid. Reachable
  from a pencil icon next to each type badge on `Web.MachineFormLive`'s
  General tab, or by direct URL (`Paths.machine_type_template/1`).

  ## Row shape & validation

  Reuses the row shape and per-row validation rules of the pre-migration
  `machine_type_form_live.ex` (removed in E12): each row is a string-keyed
  map with `key` (`~r/^[a-z0-9_]+$/`, must be unique within the template),
  `label`, `type` (`text`/`number`/`date`/`boolean`/`select`), an optional
  `unit`, an optional `required` flag, and — mandatory and non-empty only
  when `type == "select"` — an `options` list. Unlike the removed schema's
  version, validation here is plain Elixir (`validate_rows/1`), not an Ecto
  changeset — `field_template` is a nested array inside `EntityData`'s
  freeform `metadata` map, not a field of its own to `cast/3`.

  `@field_template_rows` is a plain assign, not changeset-bound: every row
  input uses a raw `name="field_template[IDX][key]"` (not `@form[:atom]`),
  refreshed from submitted params on every `phx-change="validate"`, same
  convention `MachineFormLive` uses for its dynamic `metadata` inputs.

  ## Persistence

  Saves via `EntityData.update/3` with only `metadata:` in the attrs —
  `Map.merge`d onto the record's *existing* metadata (not replaced) so
  `legacy_uuid` (and any other key living there) survives untouched. Reads
  are a plain `EntityData.get/2` (not through `EntitiesRegistry` — this page
  edits a single record it already knows the uuid of, so the ETS cache
  buys nothing); `EntityData.update/3` broadcasts its own
  `PhoenixKitEntities.Events` message, so `EntitiesRegistry` picks up the
  change on its own.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitManufacturing.Paths

  @field_template_types ~w(text number date boolean select)
  @field_template_key_format ~r/^[a-z0-9_]+$/

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header instead of an in-page one — same pattern as
  # `PhoenixKitManufacturing.Web.MachineFormLive`.
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(params, _session, socket) do
    case load_machine_type(Map.get(params, "uuid")) do
      {:ok, entity_data} ->
        {:ok,
         socket
         |> assign(
           page_title: gettext("Field Template: %{name}", name: entity_data.title),
           entity_data: entity_data,
           field_template_rows: load_rows(entity_data),
           errors: []
         )}

      {:error, :not_found} ->
        Logger.info("Machine type not found for template editor: #{inspect(params["uuid"])}")

        {:ok,
         socket
         |> put_flash(:error, gettext("Machine type not found."))
         |> push_navigate(to: Paths.types())}
    end
  end

  defp load_machine_type(uuid) do
    entity = Entities.get_entity_by_name("machine_type")

    case entity && uuid && EntityData.get(uuid) do
      %EntityData{entity_uuid: entity_uuid} = record when entity_uuid == entity.uuid ->
        {:ok, record}

      _ ->
        {:error, :not_found}
    end
  rescue
    error ->
      Logger.error("Failed to load machine type #{inspect(uuid)}: #{inspect(error)}")
      {:error, :not_found}
  end

  @impl true
  def handle_event("add_field_row", _params, socket) do
    new_row = %{
      "key" => "",
      "label" => "",
      "type" => "text",
      "unit" => "",
      "required" => false,
      "options" => []
    }

    {:noreply, update(socket, :field_template_rows, &(&1 ++ [new_row]))}
  end

  def handle_event("remove_field_row", %{"index" => index}, socket) do
    index = String.to_integer(index)
    {:noreply, update(socket, :field_template_rows, &List.delete_at(&1, index))}
  end

  def handle_event("validate", params, socket) do
    rows = rows_from_params(Map.get(params, "field_template"))
    {:noreply, assign(socket, field_template_rows: rows, errors: validate_rows(rows))}
  end

  def handle_event("save", params, socket) do
    rows = rows_from_params(Map.get(params, "field_template"))

    case validate_rows(rows) do
      [] -> persist(socket, rows)
      errors -> {:noreply, assign(socket, field_template_rows: rows, errors: errors)}
    end
  end

  # Defensive catch-all for unmatched messages. Logs at :debug.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[MachineTypeTemplateLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp persist(socket, rows) do
    entity_data = socket.assigns.entity_data
    metadata = Map.put(entity_data.metadata || %{}, "field_template", rows)

    case EntityData.update(entity_data, %{metadata: metadata}, actor_opts(socket)) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Field template saved."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        Logger.error(
          "Failed to save field template for #{entity_data.uuid}: #{inspect(changeset.errors)}"
        )

        {:noreply,
         socket
         |> assign(:field_template_rows, rows)
         |> put_flash(:error, gettext("Failed to save field template."))}
    end
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # field_template row editor — plain assign, not changeset-bound (see
  # moduledoc). Both the metadata-loaded shape and the submitted-params
  # shape normalize into the same canonical row: string key/label/type/unit,
  # a real boolean `required`, a real list `options` (parsed from the single
  # comma-separated "Options" input on submit).
  # ═══════════════════════════════════════════════════════════════════

  defp load_rows(%EntityData{metadata: metadata}) do
    (metadata || %{}) |> Map.get("field_template") |> normalize_loaded_rows()
  end

  defp normalize_loaded_rows(rows) when is_list(rows), do: Enum.map(rows, &normalize_loaded_row/1)
  defp normalize_loaded_rows(_rows), do: []

  defp normalize_loaded_row(row) when is_map(row) do
    %{
      "key" => Map.get(row, "key", ""),
      "label" => Map.get(row, "label", ""),
      "type" => Map.get(row, "type", "text"),
      "unit" => Map.get(row, "unit") || "",
      "required" => Map.get(row, "required") == true,
      "options" => normalize_options_list(Map.get(row, "options"))
    }
  end

  defp normalize_options_list(options) when is_list(options), do: options
  defp normalize_options_list(_options), do: []

  # `params["field_template"]` arrives as a map with numeric string keys
  # (`%{"0" => %{...}, "1" => %{...}}` — standard HTML indexed-field
  # encoding), sorted here into row order.
  defp rows_from_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} -> normalize_submitted_row(row) end)
  end

  defp rows_from_params(_params), do: []

  defp normalize_submitted_row(row) do
    type = Map.get(row, "type", "text")

    %{
      "key" => String.trim(Map.get(row, "key", "")),
      "label" => String.trim(Map.get(row, "label", "")),
      "type" => type,
      "unit" => String.trim(Map.get(row, "unit", "")),
      "required" => Map.get(row, "required") in ["true", "on"],
      "options" => parse_options(type, Map.get(row, "options", ""))
    }
  end

  # Only `type == "select"` renders the "Options" input at all; every other
  # type stores an empty list (valid per `validate_rows/1` — `options` is
  # only mandatory for `select`).
  defp parse_options("select", options) when is_binary(options) do
    options
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_options(_type, _options), do: []

  # Validates every row, same per-row contract as the removed
  # `Schemas.MachineType.validate_field_template/1`: a malformed row adds a
  # single "invalid row" error (not one per bad attribute); a `key` repeated
  # across rows of the same template adds a "duplicate key" error.
  defp validate_rows(rows) do
    {errors, _seen_keys} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, &validate_row/2)

    Enum.reverse(errors)
  end

  defp validate_row({row, index}, {errors, seen_keys}) do
    key = row["key"]

    cond do
      not valid_row?(row) ->
        {[gettext("Invalid row at index %{index}", index: index) | errors], seen_keys}

      MapSet.member?(seen_keys, key) ->
        {[gettext("Duplicate key: %{key}", key: key) | errors], seen_keys}

      true ->
        {errors, MapSet.put(seen_keys, key)}
    end
  end

  defp valid_row?(row) do
    key = row["key"]
    label = row["label"]
    type = row["type"]

    non_blank?(key) and String.match?(key, @field_template_key_format) and
      non_blank?(label) and
      type in @field_template_types and
      valid_options?(type, row["options"])
  end

  defp valid_options?("select", options),
    do: is_list(options) and options != [] and Enum.all?(options, &non_blank?/1)

  defp valid_options?(_type, options), do: is_list(options)

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  defp field_type_options do
    [
      {gettext("Text"), "text"},
      {gettext("Number"), "number"},
      {gettext("Date"), "date"},
      {gettext("Boolean"), "boolean"},
      {gettext("Select"), "select"}
    ]
  end

  defp options_text(options) when is_list(options), do: Enum.join(options, ", ")
  defp options_text(_options), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={gettext("Specification fields rendered on machines linked to this type.")}
      current_path={assigns[:url_path] || assigns[:current_path] || Paths.types()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-8 gap-6">
        <div class="max-w-screen-2xl mx-auto w-full">
          <form phx-change="validate" phx-submit="save">
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body flex flex-col gap-3">
                <div class="flex items-center justify-between gap-2">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-clipboard-document-list" class="w-5 h-5 text-base-content/70" />
                    <span class="font-medium">{gettext("Specification Fields")}</span>
                  </div>
                  <button type="button" phx-click="add_field_row" class="btn btn-ghost btn-sm gap-1">
                    <.icon name="hero-plus" class="w-4 h-4" />{gettext("Add field")}
                  </button>
                </div>
                <p class="text-sm text-base-content/50 -mt-2">
                  {gettext("Extra fields rendered on the machine form for machines linked to this type.")}
                </p>

                <p :if={@field_template_rows == []} class="text-sm text-base-content/50 italic">
                  {gettext("No fields yet — click \"Add field\" to define one.")}
                </p>

                <div :for={msg <- @errors} class="text-sm text-error">{msg}</div>

                <.field_template_row
                  :for={{row, index} <- Enum.with_index(@field_template_rows)}
                  row={row}
                  index={index}
                />

                <div class="divider my-0"></div>

                <div class="flex justify-end gap-3">
                  <.link navigate={Paths.types()} class="btn btn-ghost">{gettext("Cancel")}</.link>
                  <button
                    type="submit"
                    class="btn btn-primary phx-submit-loading:opacity-75"
                    phx-disable-with={gettext("Saving...")}
                  >
                    {gettext("Save Changes")}
                  </button>
                </div>
              </div>
            </div>
          </form>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  attr(:row, :map, required: true)
  attr(:index, :integer, required: true)

  defp field_template_row(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 p-4 flex flex-col gap-3">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <.input
          type="text"
          name={"field_template[#{@index}][key]"}
          value={@row["key"]}
          label={gettext("Key")}
          placeholder={gettext("e.g., power_kw")}
        />
        <.input
          type="text"
          name={"field_template[#{@index}][label]"}
          value={@row["label"]}
          label={gettext("Label")}
          placeholder={gettext("e.g., Power")}
        />
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <.select
          name={"field_template[#{@index}][type]"}
          value={@row["type"]}
          label={gettext("Type")}
          options={field_type_options()}
        />
        <.input
          type="text"
          name={"field_template[#{@index}][unit]"}
          value={@row["unit"]}
          label={gettext("Unit")}
          placeholder={gettext("optional, e.g., kW")}
        />
      </div>

      <.input
        :if={@row["type"] == "select"}
        type="text"
        name={"field_template[#{@index}][options]"}
        value={options_text(@row["options"])}
        label={gettext("Options (comma-separated)")}
        placeholder={gettext("e.g., 110V, 220V")}
      />

      <div class="flex items-center justify-between gap-3">
        <.checkbox
          name={"field_template[#{@index}][required]"}
          checked={@row["required"]}
          label={gettext("Required")}
        />
        <button
          type="button"
          phx-click="remove_field_row"
          phx-value-index={@index}
          class="btn btn-ghost btn-sm text-error gap-1"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />{gettext("Remove")}
        </button>
      </div>
    </div>
    """
  end
end
