defmodule PhoenixKitManufacturing.EntitiesRegistry do
  @moduledoc """
  ETS-backed cache of the `machine_type` / `operation` / `defect_reason`
  `phoenix_kit_entities` records, keyed by kind + uuid, with per-locale
  title resolution. Subscribes to `PhoenixKitEntities.Events` and reloads
  on any entity/entity-data change. Concurrent readers always see a
  consistent snapshot.

  Modeled 1:1 on `Host.Orders.StatusRegistry`. The three "blueprint"
  entities (`machine_type`/`operation`/`defect_reason`) are provisioned
  idempotently by `provision_blueprints/0`, retried until all three are
  confirmed present. Two retry paths run in parallel:

    * **Event-driven**: every reload (triggered by a PubSub event or an
      explicit `reload/0` call) retries provisioning at the top of
      `do_reload/1`.
    * **Timer-driven**: while `blueprints_provisioned` is `false`,
      `init/1` and each failed attempt schedule a
      `Process.send_after(self(), :retry_provision, @retry_provision_interval)`
      (default 30 s). `handle_info(:retry_provision, ...)` retries and
      reschedules if still not provisioned, and is a no-op once provisioned.
      This guarantees the subtabs become available even on a host that boots
      with no users and receives no entities PubSub events for a long time.

  See `dev_docs/ENTITIES_MIGRATION_SPEC.md` for the original design rationale.

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
  alias PhoenixKit.Users.Auth
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

  # While `blueprints_provisioned` is `false` (no users exist yet, or the
  # entities tables haven't been migrated), the init/1 and each failed
  # provisioning attempt schedule a timer to retry after this interval.
  @retry_provision_interval 30_000

  # Blueprint entity definitions provisioned idempotently by
  # `provision_blueprints/0` below. Ported from the module's own pre-V144
  # migration (`Migrations.Machines` V5, since removed — see
  # `dev_docs/LEGACY_DATA_MIGRATION.md`); the entities themselves live in
  # PhoenixKit core's entities system (`phoenix_kit_entities`, migration
  # V17), not this module's own tables.
  @blueprint_directories [
    %{
      name: "machine_type",
      display_name: "Machine Type",
      display_name_plural: "Machine Types",
      icon: "hero-tag",
      fields_definition: [
        %{
          "type" => "textarea",
          "key" => "description",
          "label" => "Description",
          "translatable" => true
        }
      ],
      translations: %{
        "ru" => %{"display_name" => "Тип станка", "display_name_plural" => "Типы станков"},
        "et" => %{"display_name" => "Masinatüüp", "display_name_plural" => "Masinatüübid"}
      }
    },
    %{
      name: "operation",
      display_name: "Operation",
      display_name_plural: "Operations",
      icon: "hero-clock",
      fields_definition: [
        %{"type" => "text", "key" => "unit", "label" => "Unit"},
        %{
          "type" => "number",
          "key" => "base_time_norm_seconds",
          "label" => "Base time norm (seconds)"
        }
      ],
      translations: %{
        "ru" => %{"display_name" => "Операция", "display_name_plural" => "Операции"},
        "et" => %{"display_name" => "Toiming", "display_name_plural" => "Toimingud"}
      }
    },
    %{
      name: "defect_reason",
      display_name: "Defect Reason",
      display_name_plural: "Defect Reasons",
      icon: "hero-exclamation-triangle",
      fields_definition: [
        %{
          "type" => "textarea",
          "key" => "description",
          "label" => "Description",
          "translatable" => true
        }
      ],
      translations: %{
        "ru" => %{
          "display_name" => "Причина брака",
          "display_name_plural" => "Причины брака"
        },
        "et" => %{"display_name" => "Praagi põhjus", "display_name_plural" => "Praagi põhjused"}
      }
    }
  ]

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
    provisioned = do_reload(false)

    unless provisioned,
      do: Process.send_after(self(), :retry_provision, @retry_provision_interval)

    {:ok, %{blueprints_provisioned: provisioned}}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:reply, :ok, %{state | blueprints_provisioned: do_reload(state.blueprints_provisioned)}}
  end

  @impl true
  def handle_info({event, entity_uuid, _data_uuid}, state)
      when event in [:data_created, :data_updated, :data_deleted] do
    if our_entity?(entity_uuid) do
      {:noreply, %{state | blueprints_provisioned: do_reload(state.blueprints_provisioned)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:data_reordered, entity_uuid}, state) do
    if our_entity?(entity_uuid) do
      {:noreply, %{state | blueprints_provisioned: do_reload(state.blueprints_provisioned)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({event, _entity_uuid}, state)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    # Entity-definition events carry only the entity uuid, not the entity name.
    # Filtering by uuid would require a DB lookup on every event, and a newly
    # created entity also isn't in ETS yet. Full reload is kept here; entity-
    # definition changes are rare in practice.
    {:noreply, %{state | blueprints_provisioned: do_reload(state.blueprints_provisioned)}}
  end

  # Timer-based retry for blueprint provisioning. Fires every
  # @retry_provision_interval ms while `blueprints_provisioned` is false.
  # Once provisioned (via any path), the flag check skips the reload and
  # stops rescheduling naturally.
  def handle_info(:retry_provision, %{blueprints_provisioned: true} = state) do
    {:noreply, state}
  end

  def handle_info(:retry_provision, state) do
    provisioned = do_reload(state.blueprints_provisioned)

    unless provisioned,
      do: Process.send_after(self(), :retry_provision, @retry_provision_interval)

    {:noreply, %{state | blueprints_provisioned: provisioned}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internal ##

  # `blueprints_provisioned` is `false` until `provision_blueprints/0` has
  # confirmed all three blueprint entities exist; while `false`, every
  # reload retries provisioning first (see `provision_blueprints/0`).
  # Returns the (possibly now-`true`) flag for the caller to store back in
  # GenServer state.
  defp do_reload(blueprints_provisioned) do
    blueprints_provisioned = blueprints_provisioned or provision_blueprints()

    case build_payload() do
      {:ok, payload} -> write_payload(payload)
      :error -> :ok
    end

    blueprints_provisioned
  end

  defp write_payload(payload) do
    new_keys = MapSet.new(payload, fn {k, _v} -> k end)

    :ets.insert(@table, payload)
    :ets.insert(@table, {:ready, true})

    # Delete stale keys (present before this reload but not in the new
    # payload — e.g. a record that was trashed, or the last record of a
    # kind being removed).
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {k, _v} -> delete_if_stale(k, new_keys) end)
  end

  defp delete_if_stale(:ready, _new_keys), do: :ok

  defp delete_if_stale(key, new_keys) do
    unless MapSet.member?(new_keys, key), do: :ets.delete(@table, key)
  end

  # Wrapped exactly like `provision_blueprints/0` below: `build_kind/2` runs
  # the same `Entities.get_entity_by_name/1` read `provision_blueprints/0`
  # already rescues `Postgrex.Error :undefined_table` for, but until now
  # nothing protected *this* call — a host booting before
  # `phoenix_kit_entities`' own tables are migrated (a separate migration
  # namespace from this module's core V144 tables, see
  # `dev_docs/ENTITIES_MIGRATION_SPEC.md`) would crash `init/1` here and
  # take down the supervision tree. Leaves the ETS table untouched (empty
  # or whatever it was) on failure; the next reload (event- or
  # timer-driven) retries.
  defp build_payload do
    {:ok, Enum.flat_map(@entity_names, fn {kind, name} -> build_kind(kind, name) end)}
  rescue
    e in Postgrex.Error ->
      unless match?(%{postgres: %{code: :undefined_table}}, e) do
        Logger.warning("EntitiesRegistry: reload failed: #{Exception.message(e)}")
      end

      :error

    e ->
      Logger.warning("EntitiesRegistry: reload error: #{Exception.message(e)}")
      :error
  catch
    :exit, _ -> :error
  end

  # Idempotently creates the machine_type/operation/defect_reason blueprint
  # entities this module's directories are backed by, so a fresh host needs
  # no separate seed step. Called from `do_reload/1` above on every reload
  # until all three are confirmed present: a host can boot with zero
  # PhoenixKit users (see `resolve_creator_uuid/0`) or before core has
  # migrated the entities tables, both transient conditions — this
  # passively retries on the next reload (PubSub-triggered, or an explicit
  # `reload/0` call) rather than raising or wiring up an active retry hook.
  #
  # Wrapped so no outcome ever blocks GenServer/supervision-tree startup —
  # mirrors this module's `Postgrex.Error :undefined_table` convention
  # (see `Machines.maybe_log_activity/5`) plus the sandbox-owner-exited
  # `catch :exit` from `PhoenixKitManufacturing.enabled?/0`.
  defp provision_blueprints do
    case resolve_creator_uuid() do
      {:ok, creator_uuid} ->
        @blueprint_directories
        |> Enum.map(&ensure_blueprint_entity(&1, creator_uuid))
        |> Enum.all?(&match?({:ok, _}, &1))

      :no_users ->
        Logger.warning(
          "EntitiesRegistry: no PhoenixKit users yet — deferring blueprint provisioning"
        )

        false
    end
  rescue
    e in Postgrex.Error ->
      unless match?(%{postgres: %{code: :undefined_table}}, e) do
        Logger.warning("EntitiesRegistry: blueprint provisioning failed: #{Exception.message(e)}")
      end

      false

    e ->
      Logger.warning("EntitiesRegistry: blueprint provisioning error: #{Exception.message(e)}")
      false
  catch
    :exit, _ -> false
  end

  # Resolves who newly-provisioned blueprint entities are attributed to.
  # `:no_users` on a host with none yet (fresh install, before the first
  # admin signs up) — `provision_blueprints/0` skips this pass and retries
  # on the next `do_reload/1`.
  defp resolve_creator_uuid do
    case Auth.get_first_admin_uuid() || Auth.get_first_user_uuid() do
      nil -> :no_users
      uuid -> {:ok, uuid}
    end
  end

  # Idempotent: returns the existing entity by name if the blueprint was
  # already provisioned by an earlier pass (this process or a concurrent
  # one).
  defp ensure_blueprint_entity(spec, creator_uuid) do
    case Entities.get_entity_by_name(spec.name) do
      nil -> create_blueprint_entity(spec, creator_uuid)
      existing -> {:ok, existing}
    end
  end

  # No hard `{:ok, _}` match on `create_entity/1`: `phoenix_kit_entities`'
  # unique index on `name` (`phoenix_kit_entities_name_uidx`, core V17)
  # means a concurrent provisioner (e.g. two app nodes booting at once)
  # can win the insert first, turning ours into `{:error, changeset}`
  # rather than a crash — re-fetch to pick up whatever now exists instead
  # of trusting our own insert succeeded.
  defp create_blueprint_entity(spec, creator_uuid) do
    case Entities.create_entity(%{
           name: spec.name,
           display_name: spec.display_name,
           display_name_plural: spec.display_name_plural,
           icon: spec.icon,
           fields_definition: spec.fields_definition,
           created_by_uuid: creator_uuid
         }) do
      {:ok, entity} ->
        Enum.each(spec.translations, fn {lang, attrs} ->
          Entities.set_entity_translation(entity, lang, attrs)
        end)

        {:ok, entity}

      {:error, _changeset} ->
        case Entities.get_entity_by_name(spec.name) do
          nil -> :error
          existing -> {:ok, existing}
        end
    end
  end

  defp build_kind(kind, entity_name) do
    case Entities.get_entity_by_name(entity_name) do
      nil ->
        Logger.info("EntitiesRegistry: entity '#{entity_name}' not yet seeded")
        [{{:list, kind}, []}, {{:entity_uuid, kind}, nil}]

      entity ->
        records =
          entity.uuid
          |> EntityData.list_by_entity()
          |> Enum.sort_by(& &1.position)
          |> Enum.map(&to_record(&1, entity_name))

        list_entry = [{{:list, kind}, records}]
        per_record = Enum.map(records, fn r -> {{:by_uuid, kind, r.uuid}, r} end)

        # Store entity uuid so data-event handle_info can filter cheaply.
        [{{:entity_uuid, kind}, entity.uuid}] ++ list_entry ++ per_record
    end
  end

  # Returns true when `entity_uuid` is the uuid of one of our three blueprint
  # entities (machine_type / operation / defect_reason) as last known to ETS.
  # Used to skip full reloads for data events belonging to unrelated entities.
  defp our_entity?(entity_uuid) do
    Enum.any?(@kinds, fn kind ->
      case :ets.lookup(@table, {:entity_uuid, kind}) do
        [{_, ^entity_uuid}] -> true
        _ -> false
      end
    end)
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
