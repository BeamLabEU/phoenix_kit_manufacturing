defmodule PhoenixKitManufacturing.Web.OperationFormLive do
  @moduledoc """
  Create/edit form for the operations directory (e.g. "Cutting", "Welding",
  "Assembly"), with a multilang `name`.

  Mirrors the mount/load/save/render structure of `MachineTypeFormLive` —
  wired through core `MultilangForm` (`mount_multilang/1`,
  `merge_translatable_params/4`, `<.multilang_tabs>` /
  `<.multilang_fields_wrapper>` / `<.translatable_field>`) — but simpler:
  only `name` is translatable (`Schemas.Operation` has no `description`
  field), and there is no dynamic row editor like machine type's
  `field_template`.

  `unit`, `base_time_norm_seconds`, and `status` are plain, non-translatable
  columns rendered with core `<.input>`/`<.select>` outside the multilang
  wrapper. All three are listed in `@preserve_fields` so their submitted
  value survives on secondary-language tabs — mirrors `MachineTypeFormLive`'s
  own `%{"status" => :status}`.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitManufacturing.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKitManufacturing.{Errors, Operations, Paths}
  alias PhoenixKitManufacturing.Schemas.Operation

  @translatable_fields ["name"]
  @preserve_fields %{
    "unit" => :unit,
    "base_time_norm_seconds" => :base_time_norm_seconds,
    "status" => :status
  }

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_operation(action, params) do
      {:not_found, uuid} ->
        Logger.info("Operation not found for edit: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:operation_not_found))
         |> push_navigate(to: Paths.operations())}

      {operation, changeset} ->
        {:ok,
         socket
         |> assign(
           page_title: page_title(action, operation),
           action: action,
           operation: operation
         )
         |> assign_form(changeset)
         |> mount_multilang()}
    end
  end

  defp load_operation(:new, _params) do
    o = %Operation{}
    {o, Operations.change_operation(o)}
  end

  defp load_operation(:edit, params) do
    case Operations.get_operation(params["uuid"]) do
      nil -> {:not_found, params["uuid"]}
      o -> {o, Operations.change_operation(o)}
    end
  end

  defp page_title(:new, _operation), do: gettext("New Operation")
  defp page_title(:edit, operation), do: gettext("Edit %{name}", name: operation.name)

  # Keeps the `:changeset` assign (for `<.translatable_field>`) and `:form`
  # (for core `<.input>`/`<.select>` which want a `Phoenix.HTML.FormField`)
  # in sync.
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :operation))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"operation" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.operation
      |> Operations.change_operation(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"operation" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_operation(socket, socket.assigns.action, params)
  end

  # Defensive catch-all for unmatched messages. Logs at :debug.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[OperationFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp save_operation(socket, :new, params) do
    case Operations.create_operation(params, actor_opts(socket)) do
      {:ok, _operation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Operation created."))
         |> push_navigate(to: Paths.operations())}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_operation(socket, :edit, params) do
    case Operations.update_operation(socket.assigns.operation, params, actor_opts(socket)) do
      {:ok, _operation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Operation updated."))
         |> push_navigate(to: Paths.operations())}

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
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <.admin_page_header
        title={@page_title}
        subtitle={
          if @action == :new,
            do: gettext("Create a new operation for the operations directory."),
            else: gettext("Update operation details.")
        }
      />

      <div class="max-w-3xl mx-auto w-full">
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
              </:skeleton>
              <div class="card-body pt-0 flex flex-col gap-5">
                <.translatable_field
                  field_name="name"
                  form_prefix="operation"
                  changeset={@changeset}
                  schema_field={:name}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={@lang_data}
                  label={gettext("Name")}
                  placeholder={gettext("e.g., Cutting, Welding, Assembly")}
                  required
                  class="w-full"
                />
              </div>
            </.multilang_fields_wrapper>

            <div class="card-body flex flex-col gap-5 pt-0">
              <div class="divider my-0"></div>

              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@form[:unit]}
                  type="text"
                  label={gettext("Unit")}
                  placeholder={gettext("optional, e.g., pcs, m, kg")}
                />
                <.input
                  field={@form[:base_time_norm_seconds]}
                  type="number"
                  label={gettext("Base time norm (seconds)")}
                  placeholder={gettext("optional, e.g., 300")}
                />
              </div>

              <div class="divider my-0"></div>

              <div class="form-control">
                <.select
                  field={@form[:status]}
                  label={gettext("Status")}
                  options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
                  class="transition-colors focus-within:select-primary"
                />
                <span class="label-text-alt text-base-content/50 mt-1">
                  {gettext("Inactive operations won't appear in the machine operation selection.")}
                </span>
              </div>

              <div class="divider my-0"></div>

              <div class="flex justify-end gap-3">
                <.link navigate={Paths.operations()} class="btn btn-ghost">{gettext("Cancel")}</.link>
                <button
                  type="submit"
                  class="btn btn-primary phx-submit-loading:opacity-75"
                  phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
                >
                  {if @action == :new, do: gettext("Create Operation"), else: gettext("Save Changes")}
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
