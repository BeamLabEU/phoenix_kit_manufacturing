defmodule PhoenixKitManufacturing.Paths do
  @moduledoc """
  Centralized path helpers for the Manufacturing module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale
  handling. Never hardcode `"/admin/manufacturing"` in a LiveView or template
  — use these helpers instead so URL prefix changes only need updating here.

  `types/0`, `operations/0`, and `defect_reasons/0` are the exception to the
  `@base`-prefixed rule above: as of the entities migration
  (`dev_docs/ENTITIES_MIGRATION_SPEC.md`), `machine_type`/`operation`/
  `defect_reason` CRUD lives on the generic `phoenix_kit_entities` admin UI,
  not on a route owned by this module — so those three helpers point at
  `/admin/entities/:slug/data` instead of `/admin/manufacturing/...`.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/manufacturing"

  @doc "Manufacturing dashboard (module landing)."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  # ── Machines ────────────────────────────────────────────────────────

  @doc "Machines list."
  @spec machines() :: String.t()
  def machines, do: Routes.path("#{@base}/machines")

  @doc "New machine form."
  @spec machine_new() :: String.t()
  def machine_new, do: Routes.path("#{@base}/machines/new")

  @doc "Edit machine form."
  @spec machine_edit(String.t()) :: String.t()
  def machine_edit(uuid), do: Routes.path("#{@base}/machines/#{uuid}/edit")

  @doc "Machine card, Operations tab (hidden CRUD route, edit form only)."
  @spec machine_operations(String.t()) :: String.t()
  def machine_operations(uuid), do: Routes.path("#{@base}/machines/#{uuid}/operations")

  @doc "Machine card, Files tab (hidden CRUD route, edit form only)."
  @spec machine_files(String.t()) :: String.t()
  def machine_files(uuid), do: Routes.path("#{@base}/machines/#{uuid}/files")

  @doc "Machine card, Comments tab (hidden CRUD route, edit form only)."
  @spec machine_comments(String.t()) :: String.t()
  def machine_comments(uuid), do: Routes.path("#{@base}/machines/#{uuid}/comments")

  # ── Machine types ───────────────────────────────────────────────────

  @doc "Machine types list — the entities admin UI for the `machine_type` entity."
  @spec types() :: String.t()
  def types, do: Routes.path("/admin/entities/machine_type/data")

  @doc """
  Field-template editor for a single machine type (hidden CRUD route,
  `visible: false` — see `Web.MachineTypeTemplateLive`). `uuid` is the
  `machine_type` entity-data record's own uuid, not a machine's.
  """
  @spec machine_type_template(String.t()) :: String.t()
  def machine_type_template(uuid), do: Routes.path("#{@base}/machine-types/#{uuid}/template")

  # ── Operations ──────────────────────────────────────────────────────

  @doc "Operations list — the entities admin UI for the `operation` entity."
  @spec operations() :: String.t()
  def operations, do: Routes.path("/admin/entities/operation/data")

  # ── Defect reasons ──────────────────────────────────────────────────

  @doc "Defect reasons list — the entities admin UI for the `defect_reason` entity."
  @spec defect_reasons() :: String.t()
  def defect_reasons, do: Routes.path("/admin/entities/defect_reason/data")
end
