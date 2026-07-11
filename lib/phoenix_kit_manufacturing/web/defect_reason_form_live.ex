defmodule PhoenixKitManufacturing.Web.DefectReasonFormLive do
  @moduledoc """
  Create/edit form for the defect-reasons directory (e.g. "Scratched
  surface", "Wrong dimensions", "Missing part").

  Mirrors the mount/load/save/render structure of `MachineTypeFormLive` —
  wired through core `MultilangForm` (`mount_multilang/1`,
  `merge_translatable_params/4`, `<.multilang_tabs>` /
  `<.multilang_fields_wrapper>` / `<.translatable_field>`) — and, unlike
  `OperationFormLive`, both `name` *and* `description` are translatable
  (`Schemas.DefectReason` has a `description` field, same shape as
  `Schemas.MachineType`). There is no dynamic row editor: `DefectReason` has
  no `field_template`-equivalent, so unlike `MachineTypeFormLive` this form
  has no per-row editor section — `status` is the only plain,
  non-translatable field, listed in `@preserve_fields` so its submitted
  value survives on secondary-language tabs.

  Self-wraps with `LayoutWrapper.app_layout` (`:self_wrapped_layout` on_mount
  below) instead of relying on PhoenixKit's automatic admin layout, so
  `page_title`/`page_subtitle` render in the global admin header rather than
  an in-page one — same pattern as `PhoenixKitManufacturing.Web.MachinesLive`.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKitManufacturing.{DefectReasons, Errors, Paths}
  alias PhoenixKitManufacturing.Schemas.DefectReason

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

    case load_defect_reason(action, params) do
      {:not_found, uuid} ->
        Logger.info("Defect reason not found for edit: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:defect_reason_not_found))
         |> push_navigate(to: Paths.defect_reasons())}

      {defect_reason, changeset} ->
        {:ok,
         socket
         |> assign(
           page_title: page_title(action, defect_reason),
           action: action,
           defect_reason: defect_reason
         )
         |> assign_form(changeset)
         |> mount_multilang()}
    end
  end

  defp load_defect_reason(:new, _params) do
    d = %DefectReason{}
    {d, DefectReasons.change_defect_reason(d)}
  end

  defp load_defect_reason(:edit, params) do
    case DefectReasons.get_defect_reason(params["uuid"]) do
      nil -> {:not_found, params["uuid"]}
      d -> {d, DefectReasons.change_defect_reason(d)}
    end
  end

  defp page_title(:new, _defect_reason), do: gettext("New Defect Reason")
  defp page_title(:edit, defect_reason), do: gettext("Edit %{name}", name: defect_reason.name)

  # Keeps the `:changeset` assign (for `<.translatable_field>`) and `:form`
  # (for core `<.select>` which wants a `Phoenix.HTML.FormField`) in sync.
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :defect_reason))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"defect_reason" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.defect_reason
      |> DefectReasons.change_defect_reason(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"defect_reason" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_defect_reason(socket, socket.assigns.action, params)
  end

  # Defensive catch-all for unmatched messages. Logs at :debug.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[DefectReasonFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp save_defect_reason(socket, :new, params) do
    case DefectReasons.create_defect_reason(params, actor_opts(socket)) do
      {:ok, _defect_reason} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Defect reason created."))
         |> push_navigate(to: Paths.defect_reasons())}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_defect_reason(socket, :edit, params) do
    case DefectReasons.update_defect_reason(
           socket.assigns.defect_reason,
           params,
           actor_opts(socket)
         ) do
      {:ok, _defect_reason} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Defect reason updated."))
         |> push_navigate(to: Paths.defect_reasons())}

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
          do: gettext("Create a new defect reason for the defect reasons directory."),
          else: gettext("Update defect reason details.")
      }
      current_path={assigns[:url_path] || assigns[:current_path] || Paths.defect_reasons()}
      current_locale={assigns[:current_locale]}
    >
      <div class="flex flex-col w-full px-4 py-8 gap-6">
        <div class="max-w-none mx-auto w-full">
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
                    form_prefix="defect_reason"
                    changeset={@changeset}
                    schema_field={:name}
                    multilang_enabled={@multilang_enabled}
                    current_lang={@current_lang}
                    primary_language={@primary_language}
                    lang_data={@lang_data}
                    label={gettext("Name")}
                    placeholder={gettext("e.g., Scratched surface, Wrong dimensions, Missing part")}
                    required
                    class="w-full"
                  />

                  <.translatable_field
                    field_name="description"
                    form_prefix="defect_reason"
                    changeset={@changeset}
                    schema_field={:description}
                    multilang_enabled={@multilang_enabled}
                    current_lang={@current_lang}
                    primary_language={@primary_language}
                    lang_data={@lang_data}
                    label={gettext("Description")}
                    type="textarea"
                    placeholder={gettext("Brief description of this defect reason...")}
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
                    {gettext("Inactive defect reasons won't appear in the defect reason selection.")}
                  </span>
                </div>

                <div class="divider my-0"></div>

                <div class="flex justify-end gap-3">
                  <.link navigate={Paths.defect_reasons()} class="btn btn-ghost">{gettext("Cancel")}</.link>
                  <button
                    type="submit"
                    class="btn btn-primary phx-submit-loading:opacity-75"
                    phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
                  >
                    {if @action == :new, do: gettext("Create Defect Reason"), else: gettext("Save Changes")}
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
end
