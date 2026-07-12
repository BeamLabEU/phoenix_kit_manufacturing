defmodule PhoenixKitManufacturing.Web.MachineTypeFormLive do
  @moduledoc """
  Create/edit form for machine types, with multilang name/description.

  ## Admin chrome

  Self-wraps with `LayoutWrapper.app_layout` (`:self_wrapped_layout` on_mount
  below) instead of relying on PhoenixKit's automatic admin layout, so
  `page_title`/`page_subtitle` render in the global admin header rather than
  an in-page one — same pattern as `PhoenixKitManufacturing.Web.MachinesLive`.

  ## `field_template` row editor

  Each machine type can define a `field_template` — the list of dynamic
  `metadata` fields rendered on machines linked to this type (see
  `Schemas.MachineType`). `@field_template_rows` is a plain list of
  string-keyed maps, not bound to the changeset: `field_template` is a
  JSONB array, not a set of per-row changeset fields, so every row input
  uses a raw `name="machine_type[field_template][IDX][key]"` (not
  `@form[:atom]`) — the same raw-name convention `MachineFormLive` uses for
  its dynamic `metadata` inputs.

  `@field_template_rows` is the single source of truth for rendering *and*
  for `add_field_row`/`remove_field_row`: `phx-change="validate"` fires on
  every keystroke/select change within `<.form>` and refreshes the assign
  from the submitted params, so by the time a `phx-click` (which carries no
  form values) adds or removes a row, the assign already reflects whatever
  the user last typed.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKitManufacturing.{Errors, Machines, Paths}
  alias PhoenixKitManufacturing.Schemas.MachineType

  @translatable_fields ["name", "description"]
  @preserve_fields %{"status" => :status}

  # PhoenixKit auto-applies its admin chrome layout to external module admin
  # views via socket.private[:live_layout]. Opt out here so this view can
  # self-wrap with LayoutWrapper.app_layout and push its title/subtitle into
  # the global admin header instead of an in-page one — same pattern as
  # `PhoenixKitManufacturing.Web.MachinesLive`.
  on_mount({__MODULE__, :self_wrapped_layout})

  def on_mount(:self_wrapped_layout, _params, _session, socket) do
    {:cont, put_in(socket.private[:live_layout], {PhoenixKitWeb.Layouts, :app})}
  end

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_type(action, params) do
      {:not_found, uuid} ->
        Logger.info("Machine type not found for edit: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:machine_type_not_found))
         |> push_navigate(to: Paths.types())}

      {machine_type, changeset} ->
        {:ok,
         socket
         |> assign(
           page_title: page_title(action, machine_type),
           action: action,
           machine_type: machine_type,
           field_template_rows: load_field_template_rows(machine_type.field_template)
         )
         |> assign_form(changeset)
         |> mount_multilang()}
    end
  end

  defp load_type(:new, _params) do
    t = %MachineType{}
    {t, Machines.change_machine_type(t)}
  end

  defp load_type(:edit, params) do
    case Machines.get_machine_type(params["uuid"]) do
      nil -> {:not_found, params["uuid"]}
      t -> {t, Machines.change_machine_type(t)}
    end
  end

  defp page_title(:new, _machine_type), do: gettext("New Machine Type")
  defp page_title(:edit, machine_type), do: gettext("Edit %{name}", name: machine_type.name)

  # Keeps the `:changeset` assign (for `<.translatable_field>`) and `:form`
  # (for core `<.select>` which wants a `Phoenix.HTML.FormField`) in sync.
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :machine_type))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

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

  def handle_event("validate", %{"machine_type" => params}, socket) do
    field_template_rows = field_template_rows_from_params(params["field_template"])

    params =
      params
      |> Map.put("field_template", field_template_rows)
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.machine_type
      |> Machines.change_machine_type(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:field_template_rows, field_template_rows)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"machine_type" => params}, socket) do
    field_template_rows = field_template_rows_from_params(params["field_template"])

    params =
      params
      |> Map.put("field_template", field_template_rows)
      |> merge_translatable_params(socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    socket
    |> assign(:field_template_rows, field_template_rows)
    |> save_machine_type(socket.assigns.action, params)
  end

  # Defensive catch-all for unmatched messages. Logs at :debug.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[MachineTypeFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp save_machine_type(socket, :new, params) do
    case Machines.create_machine_type(params, actor_opts(socket)) do
      {:ok, _machine_type} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Machine type created."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_machine_type(socket, :edit, params) do
    case Machines.update_machine_type(socket.assigns.machine_type, params, actor_opts(socket)) do
      {:ok, _machine_type} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Machine type updated."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
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
  # moduledoc). Both the DB-loaded shape and the submitted-params shape
  # normalize into the same canonical row: string key/label/type/unit, a
  # real boolean `required`, a real list `options` (parsed from the single
  # comma-separated "Options" input on submit).
  # ═══════════════════════════════════════════════════════════════════

  defp load_field_template_rows(field_template) when is_list(field_template) do
    Enum.map(field_template, &normalize_loaded_field_template_row/1)
  end

  defp load_field_template_rows(_field_template), do: []

  # `machine_type.field_template` is always string-keyed here — it comes
  # straight off the Ecto struct (JSONB decode never produces atom keys).
  defp normalize_loaded_field_template_row(row) when is_map(row) do
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
  # encoding, Plug never auto-collapses this into a list), sorted here into
  # row order before Ecto's `{:array, :map}` cast can accept it.
  defp field_template_rows_from_params(field_template_params)
       when is_map(field_template_params) do
    field_template_params
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, row} -> normalize_submitted_field_template_row(row) end)
  end

  defp field_template_rows_from_params(_field_template_params), do: []

  defp normalize_submitted_field_template_row(row) do
    type = Map.get(row, "type", "text")

    %{
      "key" => String.trim(Map.get(row, "key", "")),
      "label" => String.trim(Map.get(row, "label", "")),
      "type" => type,
      "unit" => String.trim(Map.get(row, "unit", "")),
      "required" => Map.get(row, "required") in ["true", "on"],
      "options" => parse_field_template_options(type, Map.get(row, "options", ""))
    }
  end

  # Only `type == "select"` renders the "Options" input at all; every other
  # type stores an empty list (valid per `MachineType`'s own validation —
  # `options` is optional outside `select`).
  defp parse_field_template_options("select", options) when is_binary(options) do
    options
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_field_template_options(_type, _options), do: []

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
    assigns =
      assign(
        assigns,
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_subtitle={
        if @action == :new,
          do: gettext("Create a new machine type for categorizing machines."),
          else: gettext("Update machine type details.")
      }
      current_path={assigns[:url_path] || assigns[:current_path] || Paths.types()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-8 gap-6">
        <div class="max-w-screen-2xl mx-auto w-full">
          <.form for={@form} action="#" phx-change="validate" phx-submit="save">
            <div class="card bg-base-100 shadow-lg">
              <.multilang_tabs
                multilang_enabled={@multilang_enabled}
                language_tabs={@language_tabs}
                current_lang={@current_lang}
                class="card-body pb-0 pt-4"
              />

              <.multilang_fields_wrapper
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                skeleton_class="card-body pt-0 flex flex-col gap-5"
              >
                <:skeleton>
                  <div class="form-control">
                    <div class="label"><div class="skeleton h-4 w-14"></div></div>
                    <div class="skeleton h-12 w-full rounded-lg"></div>
                  </div>
                  <div class="form-control">
                    <div class="label"><div class="skeleton h-4 w-24"></div></div>
                    <div class="skeleton h-20 w-full rounded-lg"></div>
                  </div>
                </:skeleton>
                <div class="card-body pt-0 flex flex-col gap-5">
                  <.translatable_field
                    field_name="name"
                    form_prefix="machine_type"
                    changeset={@changeset}
                    schema_field={:name}
                    multilang_enabled={@multilang_enabled}
                    current_lang={@current_lang}
                    primary_language={@primary_language}
                    lang_data={@lang_data}
                    label={gettext("Name")}
                    placeholder={gettext("e.g., CNC, Milling, Press, Laser cutter")}
                    required
                    class="w-full"
                  />

                  <.translatable_field
                    field_name="description"
                    form_prefix="machine_type"
                    changeset={@changeset}
                    schema_field={:description}
                    multilang_enabled={@multilang_enabled}
                    current_lang={@current_lang}
                    primary_language={@primary_language}
                    lang_data={@lang_data}
                    label={gettext("Description")}
                    type="textarea"
                    placeholder={gettext("Brief description of this machine type...")}
                    class="w-full"
                  />
                </div>
              </.multilang_fields_wrapper>

              <div class="card-body flex flex-col gap-5 pt-0">
                <div class="divider my-0"></div>

                <div class="form-control">
                  <.select
                    field={@form[:status]}
                    label={gettext("Status")}
                    options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
                    class="transition-colors focus-within:select-primary"
                  />
                  <span class="label-text-alt text-base-content/50 mt-1">
                    {gettext("Inactive types won't appear in the machine type selection.")}
                  </span>
                </div>

                <div class="divider my-0"></div>

                <div class="flex flex-col gap-3">
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

                  <.field_template_row
                    :for={{row, index} <- Enum.with_index(@field_template_rows)}
                    row={row}
                    index={index}
                  />

                  <.error :for={msg <- Enum.map(@form[:field_template].errors, &translate_error/1)}>
                    {msg}
                  </.error>
                </div>

                <div class="divider my-0"></div>

                <div class="flex justify-end gap-3">
                  <.link navigate={Paths.types()} class="btn btn-ghost">{gettext("Cancel")}</.link>
                  <button
                    type="submit"
                    class="btn btn-primary phx-submit-loading:opacity-75"
                    phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
                  >
                    {if @action == :new, do: gettext("Create Type"), else: gettext("Save Changes")}
                  </button>
                </div>
              </div>
            </div>
          </.form>
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
          name={"machine_type[field_template][#{@index}][key]"}
          value={@row["key"]}
          label={gettext("Key")}
          placeholder={gettext("e.g., power_kw")}
        />
        <.input
          type="text"
          name={"machine_type[field_template][#{@index}][label]"}
          value={@row["label"]}
          label={gettext("Label")}
          placeholder={gettext("e.g., Power")}
        />
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <.select
          name={"machine_type[field_template][#{@index}][type]"}
          value={@row["type"]}
          label={gettext("Type")}
          options={field_type_options()}
        />
        <.input
          type="text"
          name={"machine_type[field_template][#{@index}][unit]"}
          value={@row["unit"]}
          label={gettext("Unit")}
          placeholder={gettext("optional, e.g., kW")}
        />
      </div>

      <.input
        :if={@row["type"] == "select"}
        type="text"
        name={"machine_type[field_template][#{@index}][options]"}
        value={options_text(@row["options"])}
        label={gettext("Options (comma-separated)")}
        placeholder={gettext("e.g., 110V, 220V")}
      />

      <div class="flex items-center justify-between gap-3">
        <.checkbox
          name={"machine_type[field_template][#{@index}][required]"}
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
