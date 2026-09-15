defmodule PhoenixKitManufacturing.MediaReorganizer do
  @moduledoc """
  Manufacturing's media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core does not ship the engine yet. This module
  declares no `@behaviour` and returns plain maps; see
  `PhoenixKitManufacturing.media_reorganizer/0` for the registration comment.
  Once core ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts)
  :: [map()]`) already matches `Source.plan/2` — the only follow-up is
  adding `@behaviour`/`@impl`.

  `plan/2` derives the desired parent from the exact hook
  (`Attachments.parent_folder_uuid/2`) that a fresh upload uses, so a plan
  describes exactly what the module would do today. Manufacturing has no
  `:attachments_folder_name` hook — the desired name is always the
  deterministic `Attachments.folder_name_for/1` name, so a `:move` action
  here only ever changes `parent_uuid` (never renames) except for a pointer
  back-fill riding along on an otherwise-unchanged folder.

  Covers `Machine` (the only resource wired to `Attachments` today — see
  its moduledoc "future resource … can reuse it"), stale
  `machine-attachment-pending-*` upload folders, and orphaned legacy
  `machine-<uuid>` folders whose record no longer exists. Machines are
  hard-deleted (`Machines.delete_machine/2` — see its moduledoc "simple
  reference data"), so unlike catalogue's soft-delete `status: "deleted"`,
  a Machine record either exists (any lifecycle `status`) or is gone; an
  orphan here is always "record missing", never "record deleted".
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitManufacturing.Attachments
  alias PhoenixKitManufacturing.Machines
  alias PhoenixKitManufacturing.Schemas.Machine

  @pending_prefix "machine-attachment-pending-"
  @legacy_prefix "machine-"
  @default_pending_days 7

  @doc """
  Builds manufacturing's reorganizer plan: one `:move` action per machine
  whose current folder does not already match the parent-folder hook, plus
  `:trash`/`:report` actions for stale pending folders and a `:report`
  (`kind: :orphan`) per legacy folder whose machine no longer exists.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is reported as `:trash` instead of
  left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    # Desired parent (the host hook, possibly a DB lookup or a lazily
    # created folder on the host side) is resolved exactly once per record
    # here and threaded into both passes below — `orphan_actions/1` reuses
    # `desired`'s `parent_uuid`s instead of calling the hook again.
    desired = resolve_desired(all_machines(), actor_uuid)

    resource_actions(desired) ++
      orphan_actions(desired) ++
      pending_folder_actions(pending_days)
  end

  # ── Machines ─────────────────────────────────────────────────────

  defp all_machines, do: Machines.list_machines()

  defp resolve_desired(machines, actor_uuid) do
    Enum.map(machines, fn machine ->
      {:ok, name} = Attachments.folder_name_for(machine)

      %{
        record: machine,
        parent_uuid: Attachments.parent_folder_uuid(machine, actor_uuid),
        name: name,
        pointer: pointer_uuid(machine)
      }
    end)
  end

  # Every folder lookup for the whole batch runs as three preloaded queries
  # (pointer uuids, legacy names at root, legacy names under a parent)
  # instead of one-to-three individual round trips per record.
  defp resource_actions(desired) do
    by_pointer = preload_by_uuid(Enum.map(desired, & &1.pointer))
    by_root_name = preload_by_root_name(Enum.map(desired, & &1.name))
    by_parent_name = preload_by_parent_name(desired)

    desired
    |> Enum.map(&resource_action(&1, by_pointer, by_root_name, by_parent_name))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(desired, by_pointer, by_root_name, by_parent_name) do
    %{record: machine, parent_uuid: parent_uuid, name: name} = desired

    case current_folder(desired, by_pointer, by_root_name, by_parent_name) do
      nil ->
        nil

      %Folder{} = folder ->
        after_move = after_move_fun(machine, desired.pointer, folder)

        if noop_move?(folder, parent_uuid, name) and is_nil(after_move) do
          nil
        else
          %{
            source: "manufacturing",
            kind: :machine,
            label: machine.name,
            op: :move,
            folder: folder,
            parent_uuid: parent_uuid,
            name: name,
            counts: counts(folder.uuid),
            on_conflict: :suffix,
            after_move: after_move
          }
        end
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or an
  # accepted `"name (N)"` suffix variant) is a no-op — filtered here since
  # this Source has no core `Action.noop?/1` to lean on. A pointer
  # back-fill still needs the action even when the folder itself would not
  # move (`after_move_fun/3` is checked by the caller).
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  # One query for every distinct pointer uuid in the batch.
  defp preload_by_uuid(uuids) do
    case Enum.reject(Enum.uniq(uuids), &is_nil/1) do
      [] -> %{}
      uuids -> Folder |> where([f], f.uuid in ^uuids) |> repo().all() |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, at root.
  defp preload_by_root_name(names) do
    case Enum.reject(Enum.uniq(names), &is_nil/1) do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.parent_uuid))
        |> repo().all()
        |> Map.new(&{&1.name, &1})
    end
  end

  # One query for every distinct legacy name under every distinct resolved
  # parent in the batch (a name × parent cross-match, filtered client-side
  # to exact pairs when read) — still one round trip for the whole batch.
  defp preload_by_parent_name(desired) do
    names = desired |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    parents = desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if names == [] or parents == [] do
      %{}
    else
      Folder
      |> where([f], f.name in ^names and f.parent_uuid in ^parents)
      |> repo().all()
      |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
    end
  end

  # Pointer, if it still resolves to a live folder; else the legacy
  # deterministic name at root; else the legacy name under the resolved
  # parent. `nil` when none of those exist — nothing to move.
  defp current_folder(desired, by_pointer, by_root_name, by_parent_name) do
    %{name: name, parent_uuid: parent_uuid, pointer: pointer} = desired

    live_or_nil(pointer && Map.get(by_pointer, pointer)) ||
      live_or_nil(Map.get(by_root_name, name)) ||
      (parent_uuid && live_or_nil(Map.get(by_parent_name, {name, parent_uuid})))
  end

  defp live_or_nil(%Folder{trashed_at: nil} = folder), do: folder
  defp live_or_nil(_), do: nil

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer. Reloads the
  # machine at execution time (rather than closing over the plan-time
  # struct) since `Machines.update_machine/2` has no `data_owned_keys`
  # merge option — the pointer write must read-modify-write the freshest
  # `data` map to avoid clobbering concurrent multilang edits.
  defp after_move_fun(%Machine{} = machine, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(machine.uuid, folder_uuid) end
    end
  end

  defp write_pointer(machine_uuid, folder_uuid) do
    case Machines.get_machine(machine_uuid) do
      nil ->
        {:error, :not_found}

      machine ->
        data = Map.put(machine.data || %{}, "files_folder_uuid", folder_uuid)

        case Machines.update_machine(machine, %{data: data}) do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ── Pending upload folders ──────────────────────────────────────

  defp pending_folder_actions(pending_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], like(f.name, ^"#{@pending_prefix}%"))
    |> repo().all()
    |> Enum.map(&pending_folder_action(&1, cutoff))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff) do
    case counts(folder.uuid) do
      {0, 0} ->
        if DateTime.compare(folder.inserted_at, cutoff) == :lt do
          %{
            source: "manufacturing",
            kind: :pending,
            label: folder.name,
            op: :trash,
            folder: folder,
            counts: {0, 0},
            reason: "empty pending upload folder older than the retention window"
          }
        end

      {files, links} ->
        names = pending_file_names(folder.uuid)

        %{
          source: "manufacturing",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: "pending folder still has files: #{Enum.join(names, ", ")}"
        }
    end
  end

  defp pending_file_names(folder_uuid) do
    File
    |> where([f], f.folder_uuid == ^folder_uuid and f.status != "trashed")
    |> repo().all()
    |> Enum.map(& &1.original_file_name)
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`machine-<uuid>`) at the media root or under a
  # parent this batch's hook resolved to, whose uuid no longer names a
  # machine (hard-deleted — Machines has no soft-delete, see moduledoc), is
  # reported so a host can collect it. Never `:move`d or `:trash`ed here —
  # this module owns no "orphans" container; a legacy folder that IS a
  # live machine's current folder is left to `resource_action/4` above.
  # Reuses `desired`'s `parent_uuid`s (already resolved once per record in
  # `plan/2`) rather than calling the host hook again.
  defp orphan_actions(desired) do
    resolved_parents =
      desired
      |> Enum.map(& &1.parent_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        machines_by_uuid = load_candidate_machines(candidates)

        candidates
        |> Enum.map(&orphan_action(&1, machines_by_uuid))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One query for every legacy-named folder at root or under a resolved
  # parent — not a query per folder.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> repo().all()
    |> Enum.map(&{&1, legacy_uuid(&1.name)})
    |> Enum.filter(fn {_folder, uuid} -> uuid end)
  end

  # `machine-<uuid>` only — excludes `machine-attachment-pending-<uuid>`
  # explicitly (it would also fail the `Ecto.UUID.cast` below since
  # "attachment-pending-<uuid>" isn't a valid uuid, but the exclusion is
  # kept explicit rather than relying on that as documentation).
  defp legacy_uuid(name) do
    if String.starts_with?(name, @pending_prefix) do
      nil
    else
      with true <- String.starts_with?(name, @legacy_prefix),
           uuid <- String.replace_prefix(name, @legacy_prefix, ""),
           {:ok, _} <- Ecto.UUID.cast(uuid) do
        uuid
      else
        _ -> nil
      end
    end
  end

  # One query for every candidate uuid — not per folder.
  defp load_candidate_machines(candidates) do
    uuids = Enum.map(candidates, fn {_folder, uuid} -> uuid end)

    Machine
    |> where([m], m.uuid in ^uuids)
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  defp orphan_action({folder, uuid}, machines_by_uuid) do
    case Map.get(machines_by_uuid, uuid) do
      nil ->
        counts = counts(folder.uuid)

        %{
          source: "manufacturing",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: counts,
          reason: orphan_reason(counts)
        }

      %Machine{} ->
        nil
    end
  end

  defp orphan_reason({files, _links}), do: "record missing, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # Counts ALL rows regardless of status (including trashed files) — the
  # core engine re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    links =
      FolderLink
      |> where([l], l.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    {files, links}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
