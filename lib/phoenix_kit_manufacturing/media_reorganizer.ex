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
  here only ever changes `parent_uuid` (never renames a folder found by
  legacy name) except for a pointer back-fill riding along on an otherwise
  unchanged folder. A folder found through a record's live pointer is never
  renamed at all — see "Move planning" below (D6).

  A host that has not configured `:attachments_parent_folder` is left
  entirely untouched for machine moves and pointer back-fills (D1). Unlike
  catalogue's per-record parent resolution, every machine resolves to the
  very same parent (`Attachments.parent_folder_uuid/2` dispatches every
  `%Machine{}` to `parent_folder_uuid("machine", actor_uuid)` — the "scope"
  is the literal string `"machine"`, not anything specific to the record),
  so the hook only ever needs to run **once per plan**, and only when at
  least one folder exists for it to place (a live pointer target, a legacy
  `machine-<uuid>` folder anywhere, or any `machine-`-prefixed folder at
  all — covering orphans of hard-deleted machines too). See "Move planning".

  Covers `Machine` (the only resource wired to `Attachments` today — see
  its moduledoc "future resource … can reuse it"), stale
  `machine-attachment-pending-*` upload folders, and orphaned legacy
  `machine-<uuid>` folders whose record no longer exists. Machines are
  hard-deleted (`Machines.delete_machine/2` — see its moduledoc "simple
  reference data"), so unlike catalogue's soft-delete `status: "deleted"`,
  a Machine record either exists (any lifecycle `status`) or is gone; an
  orphan here is always "record missing", never "record deleted".

  ## Move planning

  1. A machine is a *candidate* when it has a live pointer
     (`data["files_folder_uuid"]`, resolved without calling any hook) or a
     live folder anywhere named after its legacy deterministic name
     (`machine-<uuid>`, also resolved without a hook — one batched query
     for the whole plan). A machine with neither is left alone: nothing
     exists to move.
  2. The parent hook runs **once** for the whole plan — never per record —
     and only when at least one candidate folder exists anywhere (X12): a
     live pointer target, a legacy-named live folder for a live machine, or
     any live `machine-`-prefixed folder at all (covers a legacy folder
     whose machine was hard-deleted, so orphan detection under the resolved
     parent still works even when no machine is a move candidate — X13).
  3. A machine's *current* folder is: its live pointer if it has one (kept
     as-is, `name: nil` — the owner may have renamed it, this module never
     renames a cached folder — D6); else the legacy-named live folder under
     the resolved parent or at root (module's own lookup order — same as
     `Attachments.find_folder_by_name/2`, which checks parent first, root
     second). A legacy name live in **both** places is unresolvable —
     reported as one `kind: :duplicate` action naming both folders, nothing
     moved (X11/D2).
  4. Two (or more) machines whose current folder resolves to the very same
     live folder are likewise unresolvable — one `kind: :duplicate` report
     per shared folder, no move for any of them (X5).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitManufacturing.Attachments
  alias PhoenixKitManufacturing.Machines
  alias PhoenixKitManufacturing.Schemas.Machine

  @pending_prefix "machine-attachment-pending-"
  @legacy_prefix "machine-"
  @default_pending_days 7

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds manufacturing's reorganizer plan: one `:move` action per machine
  whose current folder does not already match the parent-folder hook,
  `:report` (`kind: :duplicate`) actions for folders that cannot be
  unambiguously resolved, `:trash`/`:report` actions for stale pending
  folders, and a `:report` (`kind: :orphan`) per legacy folder whose
  machine no longer exists.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is reported as `:trash` instead of
  left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    {resource_actions, claimed_uuids, resolved_parent} = resource_plan(actor_uuid)

    resource_actions ++
      orphan_actions(resolved_parent) ++
      pending_folder_actions(pending_days, claimed_uuids)
  end

  # ── Machines ─────────────────────────────────────────────────────

  defp resource_plan(actor_uuid) do
    if hook_configured?() do
      build_resource_plan(all_machines(), actor_uuid)
    else
      {[], MapSet.new(), nil}
    end
  end

  defp hook_configured? do
    match?(
      {mod, fun} when is_atom(mod) and is_atom(fun),
      Application.get_env(:phoenix_kit_manufacturing, :attachments_parent_folder)
    )
  end

  defp all_machines, do: Machines.list_machines()

  # Candidate detection needs no hook call: a live pointer (uuid lookup) or
  # a live folder anywhere named after the machine's legacy name. The
  # parent hook — a single value shared by every machine, see moduledoc —
  # runs at most once, and only when there is something anywhere for it to
  # place (a move candidate above, or any legacy-prefixed folder at all, so
  # orphans of hard-deleted machines are still found under the resolved
  # parent — X12/X13).
  defp build_resource_plan(machines, actor_uuid) do
    prelim =
      Enum.map(machines, fn machine ->
        {:ok, legacy_name} = Attachments.folder_name_for(machine)

        %{
          record: machine,
          pointer: valid_uuid(pointer_uuid(machine)),
          legacy_name: legacy_name
        }
      end)

    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    if map_size(by_pointer) == 0 and map_size(by_name) == 0 and not any_legacy_named_folder?() do
      {[], MapSet.new(), nil}
    else
      parent_uuid = Attachments.parent_folder_uuid("machine", actor_uuid)

      candidates =
        Enum.filter(prelim, fn p ->
          (p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
            Map.has_key?(by_name, p.legacy_name)
        end)

      entries = Enum.map(candidates, &resolve_entry(&1, parent_uuid, by_pointer, by_name))

      {unique, ambiguous_dup, shared_dup} = classify_entries(entries)

      move_actions =
        unique |> Enum.map(&build_move_action(&1, parent_uuid)) |> Enum.reject(&is_nil/1)

      dup_actions = Enum.map(ambiguous_dup, &build_ambiguous_duplicate_action/1)
      shared_actions = Enum.map(shared_dup, &build_shared_duplicate_action/1)

      all_actions = move_actions ++ dup_actions ++ shared_actions
      claimed = claimed_folder_uuids(unique, ambiguous_dup, shared_dup)

      {finalize_counts(all_actions), claimed, parent_uuid}
    end
  end

  # Resolves one machine's current folder. `:pointer` when its live pointer
  # names a folder (kept as-is downstream — D6: never renamed). Otherwise
  # the legacy name is looked up under the resolved parent and at root
  # (module's own order — `Attachments.find_folder_by_name/2` checks parent
  # first, root second); a live match at both is ambiguous.
  defp resolve_entry(p, parent_uuid, by_pointer, by_name) do
    pointer_folder = p.pointer && Map.get(by_pointer, p.pointer)

    if pointer_folder do
      Map.merge(p, %{folder: pointer_folder, via: :pointer, ambiguous: nil})
    else
      matches = Map.get(by_name, p.legacy_name, [])
      under_parent = parent_uuid && Enum.find(matches, &(&1.parent_uuid == parent_uuid))
      at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

      case {under_parent, at_root} do
        {nil, nil} -> Map.merge(p, %{folder: nil, via: nil, ambiguous: nil})
        {same, same} -> Map.merge(p, %{folder: same, via: :name, ambiguous: nil})
        {f, nil} -> Map.merge(p, %{folder: f, via: :name, ambiguous: nil})
        {nil, f} -> Map.merge(p, %{folder: f, via: :name, ambiguous: nil})
        {f1, f2} -> Map.merge(p, %{folder: nil, via: nil, ambiguous: {f1, f2}})
      end
    end
  end

  # Splits resolved entries into: `unique` (one machine ↔ one folder, safe
  # to plan a move for), `ambiguous_dup` (one machine, legacy name live at
  # both root and under the resolved parent — X11), `shared_dup` (two or
  # more machines resolving to the very same live folder — X5). Every entry
  # in the two dup buckets becomes a `:report kind: :duplicate` instead of
  # a `:move`.
  defp classify_entries(entries) do
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, _without_folder} = Enum.split_with(normal, & &1.folder)

    grouped = Enum.group_by(with_folder, & &1.folder.uuid)

    {shared, unique} =
      Enum.reduce(grouped, {[], []}, fn {_uuid, group}, {shared_acc, unique_acc} ->
        if length(group) > 1 do
          {[group | shared_acc], unique_acc}
        else
          {shared_acc, group ++ unique_acc}
        end
      end)

    {unique, ambiguous, shared}
  end

  defp claimed_folder_uuids(unique, ambiguous_dup, shared_dup) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous_dup, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.map(shared_dup, fn [%{folder: f} | _] -> f.uuid end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) and needs no pointer back-fill
  # is a no-op — filtered here since this Source has no core
  # `Action.noop?/1` to lean on. D6: a folder found through the machine's
  # pointer keeps `name: nil` (never renamed); only a folder found by
  # legacy name gets the desired name.
  defp build_move_action(%{via: :pointer} = entry, parent_uuid),
    do: move_action(entry, parent_uuid, nil)

  defp build_move_action(%{via: :name} = entry, parent_uuid),
    do: move_action(entry, parent_uuid, entry.legacy_name)

  defp move_action(%{record: machine, folder: folder} = entry, parent_uuid, name) do
    after_move = after_move_fun(machine, entry.pointer, folder)

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
        counts: nil,
        on_conflict: :suffix,
        after_move: after_move
      }
    end
  end

  # `name: nil` (a pointer-found folder, D6) — this module never renames
  # it, so only the parent needs to match for the move to be a no-op.
  defp noop_move?(%Folder{parent_uuid: parent_uuid}, parent_uuid, nil), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name)
       when is_binary(name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  defp build_ambiguous_duplicate_action(%{record: machine, ambiguous: {f1, f2}}) do
    %{
      source: "manufacturing",
      kind: :duplicate,
      label: machine.name,
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
    }
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: "manufacturing",
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one record: #{labels}"
    }
  end

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  # X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query (which would raise a CastError).
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> uuid
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil

  # One query for every distinct (valid) pointer uuid in the batch — live
  # folders only (X2).
  defp preload_by_uuid(uuids) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, matching a live
  # folder ANYWHERE (any parent, including root) — grouped by name so more
  # than one live match (different parents) is visible to `resolve_entry/4`
  # (X11). Live only (X2 — the unique index is partial, a trashed twin must
  # not hide the live folder).
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # X12: whether the parent hook is worth calling at all — cheap existence
  # check (SQL, not loaded) for any live `machine-`-prefixed folder
  # (excluding pending uploads), so a legacy folder left behind by a
  # hard-deleted machine (no longer in `all_machines/0`, so it can't show
  # up in `by_pointer`/`by_name` above) still makes the hook run once,
  # closing the orphan-under-parent gap (X13) without calling the hook on a
  # host with nothing machine-related to place.
  defp any_legacy_named_folder? do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> where([f], not like(f.name, ^"#{@pending_prefix}%"))
    |> repo().aggregate(:count) > 0
  end

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer. D7: writes
  # the owned jsonb key directly (locked row, plain changeset) — no context
  # `update_*`, no Activity log, no PubSub, no full validation.
  defp after_move_fun(%Machine{} = machine, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(machine.uuid, folder_uuid) end
    end
  end

  defp write_pointer(machine_uuid, folder_uuid) do
    case locked_machine(machine_uuid) do
      nil ->
        {:error, :not_found}

      machine ->
        data = Map.put(machine.data || %{}, "files_folder_uuid", folder_uuid)

        machine
        |> Ecto.Changeset.change(data: data)
        |> repo().update()
        |> case do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp locked_machine(uuid) do
    Machine
    |> where([m], m.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
  end

  # ── Pending upload folders ──────────────────────────────────────

  # X4: a folder any live machine currently points at is never
  # independently reported/trashed as a pending folder — its move (or
  # duplicate report) action above already covers it.
  defp pending_folder_actions(pending_days, claimed_uuids) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@pending_prefix}%"))
      |> repo().all()
      |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))

    counts = counts_by_folder(Enum.map(folders, & &1.uuid))

    folders
    |> Enum.map(&pending_folder_action(&1, cutoff, counts))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff, counts) do
    case folder_counts(counts, folder.uuid) do
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
        %{
          source: "manufacturing",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: pending_reason(folder.uuid, files, links)
        }
    end
  end

  # Names of files still sitting directly in the folder or linked into it
  # from elsewhere (so a links-only pending folder still names something).
  # Falls back to a plain count when nothing has a name to show (e.g. every
  # remaining row is a trashed file, excluded here on purpose — `counts`
  # above tells the operator how many, this reason tells them what if it
  # can).
  defp pending_reason(folder_uuid, files, links) do
    case pending_file_names(folder_uuid) do
      [] -> "pending folder still has #{files} file(s), #{links} link(s)"
      names -> "pending folder still has files: #{Enum.join(names, ", ")}"
    end
  end

  defp pending_file_names(folder_uuid) do
    linked_subq =
      from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

    File
    |> where(
      [f],
      (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked_subq)) and
        f.status != "trashed"
    )
    |> repo().all()
    |> Enum.map(& &1.original_file_name)
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`machine-<uuid>`) at the media root or under the
  # resolved parent, whose uuid no longer names a machine (hard-deleted —
  # Machines has no soft-delete, see moduledoc), is reported so a host can
  # collect it. Never `:move`d or `:trash`ed here — this module owns no
  # "orphans" container; a legacy folder that IS a live machine's current
  # folder is left to `build_move_action/2` above.
  defp orphan_actions(resolved_parent) do
    case legacy_candidate_folders(resolved_parent) do
      [] ->
        []

      candidates ->
        machines_by_uuid = load_candidate_machines(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _uuid} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, machines_by_uuid, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under the resolved
  # parent whose name starts with the machine legacy prefix.
  defp legacy_candidate_folders(resolved_parent) do
    base =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@legacy_prefix}%"))

    scoped =
      if resolved_parent do
        where(base, [f], is_nil(f.parent_uuid) or f.parent_uuid == ^resolved_parent)
      else
        where(base, [f], is_nil(f.parent_uuid))
      end

    scoped
    |> repo().all()
    |> Enum.map(&{&1, legacy_uuid(&1.name)})
    |> Enum.filter(fn {_folder, uuid} -> uuid end)
  end

  # `machine-<uuid>` only — excludes `machine-attachment-pending-<uuid>`
  # explicitly. X7: a strict UUID regex on the suffix (36-char canonical
  # form) — not `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary
  # and would key the map differently than the record's (lowercased) uuid.
  defp legacy_uuid(name) do
    with false <- String.starts_with?(name, @pending_prefix),
         true <- String.starts_with?(name, @legacy_prefix),
         suffix = String.replace_prefix(name, @legacy_prefix, ""),
         true <- Regex.match?(@uuid_regex, suffix) do
      String.downcase(suffix)
    else
      _ -> nil
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

  defp orphan_action({folder, uuid}, machines_by_uuid, counts) do
    case Map.get(machines_by_uuid, uuid) do
      nil ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: "manufacturing",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: orphan_reason(folder_counts)
        }

      %Machine{} ->
        nil
    end
  end

  defp orphan_reason({files, _links}), do: "record missing, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # for the whole plan's folder set — never a query per action. Counts ALL
  # rows regardless of status (including trashed files) — the core engine
  # re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/2` with a
  # single batched lookup across every `:move` action's folder — the whole
  # plan's move-folder counts come from one pair of grouped queries (X1),
  # not one pair per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
