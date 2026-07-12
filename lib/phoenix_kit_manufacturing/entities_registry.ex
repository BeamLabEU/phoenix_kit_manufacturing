defmodule PhoenixKitManufacturing.EntitiesRegistry do
  @moduledoc """
  ETS-backed cache of the `machine_type` / `operation` / `defect_reason`
  `phoenix_kit_entities` records, keyed by kind + uuid, with per-locale
  title resolution. Subscribes to `PhoenixKitEntities.Events` and reloads
  on any entity/entity-data change. Concurrent readers always see a
  consistent snapshot.

  Modeled 1:1 on `Andi.Orders.StatusRegistry`. The three "blueprint"
  entities are provisioned by this registry's own idempotent `init/1` — see
  below (also `dev_docs/ENTITIES_MIGRATION_SPEC.md` for the original design
  rationale).

  Not wired into `children/0` by this module alone — see
  `PhoenixKitManufacturing.children/0` for supervision-tree wiring.

  ## Record shape

  Every cached record is a plain map:

      %{
        uuid: "01…",
        entity_name: "machine_type",
        status: "published",
        position: 0,
        metadata: %{"field_template" => [...], "legacy_uuid" => "…"},
        primary_title: "CNC Mill",
        titles: %{"en-US" => "CNC Mill", "et-EE" => "CNC-frees"},
        name: "CNC Mill",
        unit: nil,
        base_time_norm_seconds: nil
      }

  `titles` only carries the locale keys actually present on that
  record's `data` — it is not restricted to the host's currently
  "enabled" languages, so a translation someone filled in survives even
  while that language is temporarily disabled site-wide.

  `name` is a convenience field: the record's primary-language title by
  default (as returned by `get/2`), or the title resolved for the
  locale requested via `list/3` / `label/3`. `unit` /
  `base_time_norm_seconds` only carry a value for `:operation` records —
  they are read once from the primary-language data block and never
  locale-overridden, even though the generic entities form technically
  allows editing them on secondary language tabs (see
  `dev_docs/ENTITIES_MIGRATION_SPEC.md` §5 — a known, accepted
  limitation of the generic-UI approach). `metadata` is passed through
  raw so callers (e.g. `Machines.merged_field_template/2`, which reads
  `metadata["field_template"]`) can access `machine_type`-specific keys
  this registry itself doesn't interpret.

  ## Locale handling

  Callers pass this module's own bare Gettext locale codes (`"en"`,
  `"et"`, `"ru"`); `phoenix_kit_entities` stores translations under
  BCP-47 dialect codes (`"en-US"`, …). `normalize_locale/1` bridges the
  two by mapping a bare or dialect code to an *enabled* PhoenixKit
  Language sharing its prefix, falling back to the primary language for
  `nil` or an unmatched code. On a fresh host with the Languages module
  disabled, only the primary language's own prefix resolves distinctly —
  every other requested locale falls back to the primary title, which is
  the intended graceful-degradation behavior.
  """

  use GenServer
  require Logger

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitEntities, as: Entities
  alias PhoenixKitEntities.EntityData
  alias PhoenixKitEntities.Events

  @table :phoenix_kit_manufacturing_entities_registry
  @entity_names %{
    machine_type: "machine_type",
    operation: "operation",
    defect_reason: "defect_reason"
  }
  @kinds [:machine_type, :operation, :defect_reason]

  @type kind :: :machine_type | :operation | :defect_reason
  @type record :: %{
          uuid: String.t(),
          entity_name: String.t(),
          status: String.t(),
          position: integer(),
          metadata: map(),
          primary_title: String.t() | nil,
          titles: %{optional(String.t()) => String.t() | nil},
          name: String.t(),
          unit: String.t() | nil,
          base_time_norm_seconds: number() | nil
        }

  ## Public API ##

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "True once the registry has completed its initial ETS load."
  @spec ready?() :: boolean()
  def ready?, do: :ets.lookup(@table, :ready) == [{:ready, true}]

  @doc """
  Lists cached records for `kind`, with `:name` resolved for `locale`
  (a bare Gettext code or BCP-47 dialect; `nil` resolves to the primary
  language — see `normalize_locale/1`).

  ## Options

    * `:status` — when given, only records with this exact status are
      returned (e.g. `"published"`). Defaults to all cached (i.e. all
      non-trashed — trashed rows are never cached in the first place)
      statuses; callers that previously filtered `status: "active"`
      should now pass `status: "published"` explicitly.
  """
  @spec list(kind(), String.t() | nil, keyword()) :: [record()]
  def list(kind, locale, opts \\ []) when kind in @kinds do
    normalized = normalize_locale(locale)
    status = Keyword.get(opts, :status)

    case :ets.lookup(@table, {:list, kind}) do
      [{_, records}] ->
        records
        |> filter_status(status)
        |> Enum.map(&resolve_name(&1, normalized))

      [] ->
        []
    end
  end

  @doc """
  Fetches a single cached record by uuid, or `nil` if unknown. `nil` is
  accepted as `uuid` (returns `nil`) so callers can pass an optional
  linked-record uuid straight through without a separate nil-check.

  Unlike `list/3`, this does not take a locale — `:name` on the
  returned record is the primary-language title (see `label/3` for
  locale-specific resolution of a single record).
  """
  @spec get(String.t() | nil, kind()) :: record() | nil
  def get(nil, _kind), do: nil

  def get(uuid, kind) when is_binary(uuid) and kind in @kinds do
    lookup(uuid, kind)
  end

  @doc """
  Resolves the title for `uuid` in `locale`, or `"Unknown"` if the uuid
  isn't cached (including `nil`).
  """
  @spec label(String.t() | nil, kind(), String.t() | nil) :: String.t()
  def label(nil, _kind, _locale), do: "Unknown"

  def label(uuid, kind, locale) when is_binary(uuid) and kind in @kinds do
    case lookup(uuid, kind) do
      nil -> "Unknown"
      record -> resolve_title(record, normalize_locale(locale))
    end
  end

  @doc "Forces an immediate synchronous reload from the database."
  @spec reload() :: :ok
  def reload, do: GenServer.call(__MODULE__, :reload)

  @doc """
  Normalizes a bare Gettext locale (`"en"`) or BCP-47 dialect
  (`"en-US"`) to the dialect code of an *enabled* PhoenixKit Language
  sharing its prefix. `nil` and codes with no enabled match fall back
  to the primary language.
  """
  @spec normalize_locale(String.t() | nil) :: String.t()
  def normalize_locale(nil), do: Multilang.primary_language()

  def normalize_locale(locale) when is_binary(locale) do
    enabled = Multilang.enabled_languages()

    if locale in enabled do
      locale
    else
      base = DialectMapper.extract_base(locale)
      Enum.find(enabled, Multilang.primary_language(), &(DialectMapper.extract_base(&1) == base))
    end
  end

  ## GenServer ##

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Events.subscribe_to_all_data()
    Events.subscribe_to_entities()
    do_reload()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    do_reload()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({event, _entity_uuid, _data_uuid}, state)
      when event in [:data_created, :data_updated, :data_deleted] do
    do_reload()
    {:noreply, state}
  end

  def handle_info({:data_reordered, _entity_uuid}, state) do
    do_reload()
    {:noreply, state}
  end

  def handle_info({event, _entity_uuid}, state)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    do_reload()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internal ##

  defp do_reload do
    payload = Enum.flat_map(@entity_names, fn {kind, name} -> build_kind(kind, name) end)
    new_keys = MapSet.new(payload, fn {k, _v} -> k end)

    :ets.insert(@table, payload)
    :ets.insert(@table, {:ready, true})

    # Delete stale keys (present before this reload but not in the new
    # payload — e.g. a record that was trashed, or the last record of a
    # kind being removed).
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {k, _v} ->
      cond do
        k == :ready -> :ok
        MapSet.member?(new_keys, k) -> :ok
        true -> :ets.delete(@table, k)
      end
    end)
  end

  defp build_kind(kind, entity_name) do
    case Entities.get_entity_by_name(entity_name) do
      nil ->
        Logger.info("EntitiesRegistry: entity '#{entity_name}' not yet seeded")
        [{{:list, kind}, []}]

      entity ->
        records =
          entity.uuid
          |> EntityData.list_by_entity()
          |> Enum.sort_by(& &1.position)
          |> Enum.map(&to_record(&1, entity_name))

        list_entry = [{{:list, kind}, records}]
        per_record = Enum.map(records, fn r -> {{:by_uuid, kind, r.uuid}, r} end)

        list_entry ++ per_record
    end
  end

  defp to_record(%EntityData{} = d, entity_name) do
    primary_data = Multilang.get_primary_data(d.data)

    %{
      uuid: d.uuid,
      entity_name: entity_name,
      status: d.status,
      position: d.position || 0,
      metadata: d.metadata || %{},
      primary_title: d.title,
      titles: build_titles(d),
      name: d.title,
      unit: Map.get(primary_data, "unit"),
      base_time_norm_seconds: Map.get(primary_data, "base_time_norm_seconds")
    }
  end

  # Only the locale keys actually present on this record's `data` — not
  # restricted to the host's currently-enabled languages (see moduledoc).
  # `EntityData.get_title_translation/2` itself falls back to `d.title`
  # for a key with no `_title` override, so every entry here resolves.
  defp build_titles(%EntityData{} = d) do
    (d.data || %{})
    |> Map.keys()
    |> Enum.reject(&(&1 == "_primary_language"))
    |> Map.new(fn code -> {code, EntityData.get_title_translation(d, code)} end)
  end

  defp resolve_name(record, locale), do: Map.put(record, :name, resolve_title(record, locale))

  defp resolve_title(%{titles: titles, primary_title: fallback}, locale) do
    Map.get(titles, locale) || fallback || "Unknown"
  end

  defp filter_status(records, nil), do: records
  defp filter_status(records, status), do: Enum.filter(records, &(&1.status == status))

  defp lookup(uuid, kind) do
    case :ets.lookup(@table, {:by_uuid, kind, uuid}) do
      [{_, r}] -> r
      _ -> nil
    end
  end
end
