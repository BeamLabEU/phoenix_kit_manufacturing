defmodule PhoenixKitManufacturing.Machines do
  @moduledoc """
  Context module for managing machines and machine types.

  Machines and types have a many-to-many relationship via a join table, so
  a machine can be tagged with several types at once (e.g. both "CNC" and
  "Milling").

  Both machines and types use hard-delete only (simple reference data).

  ## Activity logging

  Every mutating function accepts `opts \\ []`. When `actor_uuid:` is
  present in opts, the mutation is logged via `PhoenixKit.Activity.log/1`
  under the `"manufacturing"` module key. Logging failures never crash the
  primary operation — both `PhoenixKit.Activity.log/1` and this module's
  `maybe_log_activity/5` rescue internally, so on a host that has not yet
  run core's activity migration the mutation still succeeds and the failure
  degrades to a `Logger.warning`.

  ## Usage from IEx

      alias PhoenixKitManufacturing.Machines

      {:ok, cnc} = Machines.create_machine_type(%{name: "CNC"})
      {:ok, mill} = Machines.create_machine(%{name: "CNC-01", code: "M-001"})
      {:ok, _} = Machines.sync_machine_types(mill.uuid, [cnc.uuid])

      Machines.list_machines(type_uuid: cnc.uuid)
      Machines.count_machines()
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitLocations.{Locations, Spaces}
  alias PhoenixKitManufacturing.Schemas.{Machine, MachineType, MachineTypeAssignment}

  @module_key "manufacturing"

  @type opts :: keyword()
  @type status_filter :: [status: String.t()]
  @type list_machines_opts :: [status: String.t(), type_uuid: String.t()]

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Machine Types
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all machine types, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
  """
  @spec list_machine_types(status_filter) :: [MachineType.t()]
  def list_machine_types(opts \\ []) do
    MachineType
    |> from(order_by: [asc: :name])
    |> filter_status(opts)
    |> repo().all()
  end

  @doc "Fetches a machine type by UUID. Returns `nil` if not found."
  @spec get_machine_type(String.t()) :: MachineType.t() | nil
  def get_machine_type(uuid), do: repo().get(MachineType, uuid)

  @doc "Fetches a machine type by name (case-sensitive). Returns `nil` if not found."
  @spec get_machine_type_by_name(String.t()) :: MachineType.t() | nil
  def get_machine_type_by_name(name), do: repo().get_by(MachineType, name: name)

  @doc "Returns the total count of machine types."
  @spec count_machine_types(status_filter) :: non_neg_integer()
  def count_machine_types(opts \\ []) do
    MachineType
    |> from(select: count())
    |> filter_status(opts)
    |> repo().one()
  end

  @doc "Creates a machine type. Required: `:name`. Optional: `:description`, `:status`, `:data`."
  @spec create_machine_type(map(), opts) ::
          {:ok, MachineType.t()} | {:error, Ecto.Changeset.t()}
  def create_machine_type(attrs, opts \\ []) do
    %MachineType{}
    |> MachineType.changeset(attrs)
    |> repo().insert()
    |> log_activity("machine_type.created", "machine_type", opts, &type_metadata/1)
  end

  @doc "Updates a machine type with the given attributes."
  @spec update_machine_type(MachineType.t(), map(), opts) ::
          {:ok, MachineType.t()} | {:error, Ecto.Changeset.t()}
  def update_machine_type(%MachineType{} = machine_type, attrs, opts \\ []) do
    machine_type
    |> MachineType.changeset(attrs)
    |> repo().update()
    |> log_activity("machine_type.updated", "machine_type", opts, &type_metadata/1)
  end

  @doc "Hard-deletes a machine type. Cascades to type assignments (machines keep existing, lose the link)."
  @spec delete_machine_type(MachineType.t(), opts) ::
          {:ok, MachineType.t()} | {:error, Ecto.Changeset.t()}
  def delete_machine_type(%MachineType{} = machine_type, opts \\ []) do
    machine_type
    |> repo().delete()
    |> log_activity("machine_type.deleted", "machine_type", opts, &type_metadata/1)
  end

  @doc "Returns an `Ecto.Changeset` for tracking machine type changes."
  @spec change_machine_type(MachineType.t(), map()) :: Ecto.Changeset.t()
  def change_machine_type(%MachineType{} = machine_type, attrs \\ %{}) do
    MachineType.changeset(machine_type, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Machines
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all machines, ordered by name, with their types preloaded.

  ## Options

    * `:status` — filter by status.
    * `:type_uuid` — filter to only machines that have this type assigned.
  """
  @spec list_machines(list_machines_opts) :: [Machine.t()]
  def list_machines(opts \\ []) do
    query =
      Machine
      |> from(order_by: [asc: :name], preload: [:machine_types])
      |> filter_status(opts)

    query =
      case Keyword.get(opts, :type_uuid) do
        nil ->
          query

        type_uuid ->
          from(m in query,
            join: a in MachineTypeAssignment,
            on: a.machine_uuid == m.uuid,
            where: a.machine_type_uuid == ^type_uuid
          )
      end

    repo().all(query)
  end

  @doc "Fetches a machine by UUID with types preloaded. Returns `nil` if not found."
  @spec get_machine(String.t()) :: Machine.t() | nil
  def get_machine(uuid) do
    case repo().get(Machine, uuid) do
      nil -> nil
      machine -> repo().preload(machine, :machine_types)
    end
  end

  @doc "Returns the total count of machines."
  @spec count_machines(status_filter) :: non_neg_integer()
  def count_machines(opts \\ []) do
    Machine
    |> from(select: count())
    |> filter_status(opts)
    |> repo().one()
  end

  @doc """
  Creates a machine.

  Required: `:name`. Optional: `:code`, `:manufacturer`, `:serial_number`,
  `:description`, `:location_note`, `:status`, `:data`, `:metadata`.
  """
  @spec create_machine(map(), opts) :: {:ok, Machine.t()} | {:error, Ecto.Changeset.t()}
  def create_machine(attrs, opts \\ []) do
    %Machine{}
    |> Machine.changeset(attrs)
    |> repo().insert()
    |> log_activity("machine.created", "machine", opts, &machine_metadata/1)
  end

  @doc "Updates a machine with the given attributes."
  @spec update_machine(Machine.t(), map(), opts) ::
          {:ok, Machine.t()} | {:error, Ecto.Changeset.t()}
  def update_machine(%Machine{} = machine, attrs, opts \\ []) do
    machine
    |> Machine.changeset(attrs)
    |> repo().update()
    |> log_activity("machine.updated", "machine", opts, &machine_metadata/1)
  end

  @doc "Hard-deletes a machine. Cascades to type assignments."
  @spec delete_machine(Machine.t(), opts) :: {:ok, Machine.t()} | {:error, Ecto.Changeset.t()}
  def delete_machine(%Machine{} = machine, opts \\ []) do
    machine
    |> repo().delete()
    |> log_activity("machine.deleted", "machine", opts, &machine_metadata/1)
  end

  @doc "Returns an `Ecto.Changeset` for tracking machine changes."
  @spec change_machine(Machine.t(), map()) :: Ecto.Changeset.t()
  def change_machine(%Machine{} = machine, attrs \\ %{}) do
    Machine.changeset(machine, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Machine ↔ Type linking (many-to-many)
  # ═══════════════════════════════════════════════════════════════════

  @doc "Returns a list of type UUIDs linked to a machine."
  @spec linked_type_uuids(String.t()) :: [String.t()]
  def linked_type_uuids(machine_uuid) do
    from(a in MachineTypeAssignment,
      where: a.machine_uuid == ^machine_uuid,
      select: a.machine_type_uuid
    )
    |> repo().all()
  end

  @doc """
  Syncs the type assignments for a machine (full replace).

  Replaces all existing assignments with the given list of type UUIDs,
  wrapped in a transaction for atomicity. Logs `machine.types_synced` only
  when the assignment set actually changed; a no-op sync is silent.
  """
  @spec sync_machine_types(String.t(), [String.t()], opts) ::
          {:ok, :synced | :unchanged} | {:error, :type_assignment_failed}
  def sync_machine_types(machine_uuid, type_uuids, opts \\ []) do
    before_set = MapSet.new(linked_type_uuids(machine_uuid))
    after_set = MapSet.new(type_uuids)

    if MapSet.equal?(before_set, after_set) do
      {:ok, :unchanged}
    else
      result =
        repo().transaction(fn ->
          from(a in MachineTypeAssignment, where: a.machine_uuid == ^machine_uuid)
          |> repo().delete_all()

          now = DateTime.utc_now() |> DateTime.truncate(:second)
          Enum.each(type_uuids, &insert_type_assignment!(machine_uuid, &1, now))
          :synced
        end)

      case result do
        {:ok, :synced} ->
          maybe_log_activity("machine.types_synced", "machine", machine_uuid, opts, %{
            "types_from" => MapSet.to_list(before_set),
            "types_to" => MapSet.to_list(after_set)
          })

          {:ok, :synced}

        {:error, reason} ->
          maybe_log_activity("machine.types_synced", "machine", machine_uuid, opts, %{
            "db_pending" => true,
            "reason" => inspect(reason),
            "types_from" => MapSet.to_list(before_set),
            "types_to" => MapSet.to_list(after_set)
          })

          {:error, reason}
      end
    end
  end

  defp insert_type_assignment!(machine_uuid, type_uuid, now) do
    changeset =
      MachineTypeAssignment.changeset(%MachineTypeAssignment{}, %{
        machine_uuid: machine_uuid,
        machine_type_uuid: type_uuid,
        inserted_at: now,
        updated_at: now
      })

    case repo().insert(changeset) do
      {:ok, _} ->
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.error(
          "Failed to assign type #{type_uuid} to machine #{machine_uuid} (error count: #{length(cs.errors)})"
        )

        repo().rollback(:type_assignment_failed)
    end
  end

  @doc "Returns true if the machine has the given type assigned."
  @spec has_type?(String.t(), String.t()) :: boolean()
  def has_type?(machine_uuid, type_uuid) do
    query =
      from(a in MachineTypeAssignment,
        where: a.machine_uuid == ^machine_uuid and a.machine_type_uuid == ^type_uuid,
        select: true
      )

    repo().one(query) == true
  end

  # ═══════════════════════════════════════════════════════════════════
  # Passport helpers — soft location link, merged field_template
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Resolves a human-readable location label for a machine, trying (in
  order):

    1. `space_uuid` — `PhoenixKitLocations.Spaces.full_path/2`, e.g.
       `"Main Warehouse / Floor 2 / Rack 5"`.
    2. `location_uuid` — the translated name of the `Location` itself (no
       specific space picked).
    3. `location_note` — legacy freeform text for machines that predate the
       `location_uuid`/`space_uuid` link (see `Schemas.Machine`).
    4. `nil` — no location data at all.

  `phoenix_kit_locations` is a soft cross-module reference (no FK — see
  `Schemas.Machine`'s moduledoc): a uuid pointing at data this call can't
  reach (record deleted, table not migrated on this host, …) is treated as
  "no answer" and falls through to the next step rather than raising, hence
  the `rescue` around each cross-module read.

  ## Options

    * `:locale` — forwarded to `Spaces.full_path/2` / used to pick the
      translated `Location` name, same `_name` -> `name` -> primary-name
      fallback chain as `PhoenixKitLocations.Web.Components.PlacePicker`.
      `nil` (default) always shows the primary-language name.
  """
  @spec location_label(Machine.t(), opts) :: String.t() | nil
  def location_label(%Machine{} = machine, opts \\ []) do
    locale = Keyword.get(opts, :locale)

    space_label(machine.space_uuid, locale) ||
      location_name(machine.location_uuid, locale) ||
      blank_to_nil(machine.location_note)
  end

  defp space_label(space_uuid, locale) when is_binary(space_uuid) and space_uuid != "" do
    space_uuid
    |> Spaces.full_path(locale: locale)
    |> blank_to_nil()
  rescue
    _ -> nil
  end

  defp space_label(_space_uuid, _locale), do: nil

  defp location_name(location_uuid, locale)
       when is_binary(location_uuid) and location_uuid != "" do
    case Locations.get_location(location_uuid) do
      nil -> nil
      location -> translated_location_name(location, locale)
    end
  rescue
    _ -> nil
  end

  defp location_name(_location_uuid, _locale), do: nil

  defp translated_location_name(%{name: name}, nil), do: blank_to_nil(name)

  defp translated_location_name(%{data: data, name: name}, locale) do
    translation = Multilang.get_language_data(data, locale)
    blank_to_nil(Map.get(translation, "_name") || Map.get(translation, "name") || name)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc """
  Merges the `field_template` rows of every active machine type in
  `type_uuids` into a single ordered list, for rendering the dynamic
  `metadata` inputs on the machine form.

  `type_uuids` is expected to already be filtered down to "linked to this
  machine" (e.g. `MapSet.to_list/1` of the toggled type badges on the
  form) — this function does no linking lookup of its own, it only merges.

  Types are read via `list_machine_types(status: "active")`, which orders
  by `:name` — so the merge order (and therefore which type wins a key
  collision) is alphabetical by type name, **not** the order of
  `type_uuids`. When two linked types both define a `field_template` row
  with the same `key`, the earliest type in that alphabetical order wins
  and the later row is dropped silently — this is a deliberate "first
  wins" merge, not an error (unlike a duplicate key *within* one type's own
  template, which `MachineType.changeset/2` rejects at the source). Callers
  rendering the merged template SHOULD hint which type a field came from
  when a collision is possible (e.g. a "from <type name>" caption next to
  the label) — this function only resolves the winner, it doesn't surface
  which types lost.
  """
  @spec merged_field_template([String.t()]) :: [map()]
  def merged_field_template(type_uuids) when is_list(type_uuids) do
    wanted = MapSet.new(type_uuids)

    {rows, _seen_keys} =
      list_machine_types(status: "active")
      |> Enum.filter(&MapSet.member?(wanted, &1.uuid))
      |> Enum.reduce({[], MapSet.new()}, &merge_field_template_rows/2)

    Enum.reverse(rows)
  end

  defp merge_field_template_rows(%MachineType{field_template: field_template}, acc) do
    Enum.reduce(field_template, acc, &accumulate_field_template_row/2)
  end

  # "First wins": a row is only added if its key hasn't been contributed by
  # an earlier (alphabetically, by type name) type already — see the
  # `merged_field_template/1` doc for why collisions aren't an error.
  defp accumulate_field_template_row(row, {rows, seen_keys}) do
    key = field_template_row_key(row)

    if MapSet.member?(seen_keys, key) do
      {rows, seen_keys}
    else
      {[row | rows], MapSet.put(seen_keys, key)}
    end
  end

  # `field_template` rows are string-keyed once round-tripped through the
  # `field_template` JSONB column (the only source `merged_field_template/1`
  # reads from), but tolerate atom keys too for parity with
  # `Schemas.MachineType`'s own row accessor.
  defp field_template_row_key(row) when is_map(row), do: Map.get(row, "key") || Map.get(row, :key)

  # ═══════════════════════════════════════════════════════════════════
  # Query helpers
  # ═══════════════════════════════════════════════════════════════════

  defp filter_status(query, opts) do
    case Keyword.get(opts, :status) do
      nil -> query
      status -> where(query, [x], x.status == ^status)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Activity logging helpers
  # ═══════════════════════════════════════════════════════════════════

  # Pipe-step: logs on {:ok, struct} with full metadata; on
  # {:error, changeset} logs a `db_pending: true` audit row so the
  # user-initiated action survives even when the primary write fails.
  # Passes the original tuple through unchanged.
  defp log_activity({:ok, record} = ok, action, resource_type, opts, metadata_fun)
       when is_function(metadata_fun, 1) do
    maybe_log_activity(action, resource_type, Map.get(record, :uuid), opts, metadata_fun.(record))
    ok
  end

  defp log_activity(
         {:error, %Ecto.Changeset{} = changeset} = err,
         action,
         resource_type,
         opts,
         _metadata_fun
       ) do
    maybe_log_activity(
      action,
      resource_type,
      Map.get(changeset.data, :uuid),
      opts,
      changeset_error_metadata(changeset)
    )

    err
  end

  defp log_activity({:error, _} = err, _action, _resource_type, _opts, _metadata_fun), do: err

  # Low-level: fire-and-forget log, guarded so it never crashes callers.
  defp maybe_log_activity(action, resource_type, resource_uuid, opts, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: action,
        module: @module_key,
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: resource_type,
        resource_uuid: resource_uuid,
        metadata: metadata
      })
    end

    :ok
  rescue
    e in Postgrex.Error ->
      # Host hasn't run core's activity migration — swallow silently.
      if match?(%{postgres: %{code: :undefined_table}}, e) do
        :ok
      else
        Logger.warning("[Manufacturing] Activity log failed: #{Exception.message(e)}")
        :ok
      end

    e ->
      Logger.warning("[Manufacturing] Activity log error: #{Exception.message(e)}")
      :ok
  end

  # PII-safe changeset metadata: invalid field names + a db_pending marker.
  # Never includes the rejected values themselves.
  defp changeset_error_metadata(%Ecto.Changeset{errors: errors}) do
    %{
      "db_pending" => true,
      "error_fields" => errors |> Enum.map(fn {field, _} -> to_string(field) end) |> Enum.uniq()
    }
  end

  defp machine_metadata(%Machine{} = m) do
    %{"name" => m.name, "code" => m.code, "status" => m.status}
  end

  defp type_metadata(%MachineType{} = t) do
    %{"name" => t.name, "status" => t.status}
  end

  @doc """
  Logs a module enable/disable toggle. Called from the `enable_system` /
  `disable_system` module lifecycle functions.
  """
  @spec log_module_toggle(:enabled | :disabled, opts) :: :ok
  def log_module_toggle(state, opts \\ []) when state in [:enabled, :disabled] do
    maybe_log_activity(
      "manufacturing_module.#{state}",
      "module",
      nil,
      opts,
      %{"module_key" => @module_key}
    )
  end
end
