defmodule PhoenixKitManufacturing.MediaReorganizer do
  @moduledoc """
  Manufacturing's media-reorganizer plan source.

  Implements `PhoenixKit.Modules.Storage.Reorganizer.Source` (core ≥ 2.24.0)
  without declaring `@behaviour`: the `phoenix_kit ~> 2.0` pin still admits
  older cores that lack the module, where `@behaviour` would warn. `plan/2`
  (`plan(actor_uuid, opts) :: [map()]`) matches `Source.plan/2`; once the pin
  floor reaches 2.24.0 the only follow-up is adding `@behaviour`/`@impl`. See
  `PhoenixKitManufacturing.media_reorganizer/0` for the registration.

  `plan/2` calls the host's configured `:attachments_parent_folder` hook
  directly (as `hook.("machine", actor_uuid)`), rather than going through
  `Attachments.parent_folder_uuid/2` — the helper live uploads use, which
  silently degrades a raising or erroring hook to `nil` (root). Here a hook
  that raises, exits, or returns anything other than `{:ok, uuid}` (`uuid`
  cast-valid — cast through `Ecto.UUID.cast/1`, which also normalises
  case — `""` and any other malformed string never accepted) or an
  explicit `nil` is a FAILURE (R2): every move candidate is skipped, and
  the whole batch is reported once as `kind: :hook_error` (T4: always,
  even when the failure's only visible effect is that no move happens).
  Orphan detection still runs at root scope (V2/U4 — the orphan scan
  scope is root plus every parent that came from a SUCCESSFUL hook
  answer; a failed hook contributes no such parent, so the scope stays
  root-only rather than being skipped). A configured `{mod, fun}` that
  does not actually resolve to a callable function (a typo, a removed
  function) is a DIFFERENT failure
  from "no hook configured at all" (T3): it is reported as one
  `kind: :hook_error` naming the `{mod, fun}` — never silently downgraded
  to "no hook" (E1) without telling the owner why nothing moved. An
  explicit `nil`/`{:ok, nil}` (root) answer never pulls a machine's folder
  out of a parent it already lives under (F1): only the pointer back-fill
  (if any) is kept, and the machine is counted into one
  `kind: :hook_nil` report instead. Manufacturing has no
  `:attachments_folder_name` hook — the desired name is always the
  deterministic `Attachments.folder_name_for/1` name, so a `:move` action
  here only ever changes `parent_uuid` (never renames a folder found by
  legacy name) except for a pointer back-fill riding along on an otherwise
  unchanged folder. A folder found through a machine's live pointer keeps
  its own name — this module never picks a new one for it — though the
  engine's `on_conflict: :suffix` (D3) can still append the usual numeric
  suffix if that kept name collides with a different folder already live
  at the target parent. Two (or more) machines whose *desired* target
  (the resolved parent plus the kept pointer-folder name) would coincide
  are reported `kind: :duplicate` instead, since the second move would
  collide with the first at apply time (E3/F6) — this only applies among
  real `:move` candidates, computed with a working hook.

  A host that has not configured `:attachments_parent_folder` plans NO
  machine moves and NO pointer back-fills (E1) — but stale-pending and
  orphan folders are still `:report`ed; nothing is ever `:trash`ed or
  adopted without a working hook. Unlike catalogue's per-record parent
  resolution, every machine shares the very same parent (the hook's
  "scope" argument is always the literal string `"machine"`, never
  anything record-specific), so the hook only ever needs to run **once
  per plan**, and only when at least one machine is a *candidate* for a
  move (a live pointer target, or a legacy `machine-<uuid>` folder
  anywhere). **No hook call without a candidate** (F4/R8 — this
  supersedes an earlier X13 draft that ran the hook purely to widen
  orphan detection): with zero move candidates, orphan detection falls
  back to root scope only, never under a parent nobody's hook call
  verified. A folder any live machine's pointer names is never a
  pending-trash candidate regardless of whether a hook is configured
  (R1). See "Move planning".

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
     exists to move, and — F4/R8 — it never triggers the hook either.
  2. The parent hook runs **once** for the whole plan — never per record —
     and only when at least one machine is a candidate (F4/R8: no hook
     call just to widen orphan detection). A hook call that raises, exits,
     or returns anything but `{:ok, uuid}` (`uuid` cast-valid and
     case-normalised — `""` and any other malformed string are a failure
     too) or an explicit `nil` is a FAILURE, not root (R2): every
     candidate is skipped, and the batch becomes one `kind: :hook_error`
     report (T4: reported even when every candidate's move is unaffected).
     Orphan detection still runs at root scope (V2/U4 — the true parent is
     unknown, but the scan scope always includes root regardless). A
     configured hook that is not actually callable (T3) is the same kind
     of failure, reported before any candidate is even touched.
  3. A machine's *current* folder is: its live pointer if it has one (kept
     as-is, `name: nil` — the owner may have renamed it, this module never
     renames a cached folder — D6); else the legacy-named live folder under
     the resolved parent or at root (module's own lookup order — same as
     `Attachments.find_folder_by_name/2`, which checks parent first, root
     second). A legacy name live in **both** places is unresolvable —
     reported as one `kind: :duplicate` action naming both folders, nothing
     moved (X11/D2) — any THIRD live copy of the same legacy name is still
     reported `kind: :relocated` on its own, never silently swallowed by the
     duplicate report (U9). A legacy name live somewhere else entirely
     (neither root nor the resolved parent) resolves to no current folder at
     all — every such live match is reported `kind: :relocated`, never
     silently dropped (this also covers the "no pointer, no match at root or
     under the parent" case that earlier only produced a report when a
     pointer was present) — **except** when the hook answered root (F1/U1):
     a legacy folder already live under some genuine (non-root) parent is
     then adopted AS the machine's current folder instead (see point 5),
     since F1 forbids treating a nil hook answer as grounds to relocate
     anything.
  4. Two (or more) machines whose current folder resolves to the very same
     live folder are likewise unresolvable — one `kind: :duplicate` report
     per shared folder, no move for any of them (X5). Two (or more)
     machines whose current folders differ but whose *desired* target
     (resolved parent + kept name) would coincide are a separate
     `kind: :duplicate` report — the second move would collide with the
     first at apply time (E3/F6); this needs a working hook and only
     considers real move candidates.
  5. An explicit `nil`/`{:ok, nil}` hook answer never pulls a machine's
     folder out of a parent it currently lives under (F1): the move is
     suppressed (parent and name both kept exactly as-is — only a pointer
     back-fill, if any, still applies), and the machine is counted into
     one `kind: :hook_nil` report instead of a false move to root. This
     applies equally on the name track (U1): when the hook answers root but
     a legacy folder is already live under a real parent nobody's pointer
     names, that folder is treated as the machine's current one (parent and
     name kept, only the pointer back-fill runs) rather than reported
     `:relocated` — a live copy at root *and* one under some real parent at
     the same time is still ambiguous (point 3/4), and two or more live
     copies under different real parents (with none at root) are left
     unresolved, each reported `:relocated`, since nothing here can tell
     which one the hook actually meant.
  6. A live pointer's folder can leave SEPARATE legacy-named folder(s)
     (`machine-<uuid>`) live somewhere else entirely — neither the current
     folder (the pointer already names it) nor an orphan (the machine is
     live). Every such stray twin gets its own `kind: :relocated` report
     alongside whatever action the machine itself gets (F5: all of them,
     not only the first) — except a twin that is itself another live
     machine's claimed (pointer or resolved) folder, which is never also
     reported `:relocated` (T5).
  7. Orphan detection (below) excludes every folder claimed above — a
     move's current folder, a duplicate/shared/converging report's
     folders, or any live pointer target — so one folder never yields two
     actions (R4).
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
  alias PhoenixKitManufacturing.Attachments
  alias PhoenixKitManufacturing.Schemas.Machine

  @pending_prefix "machine-attachment-pending-"
  @legacy_prefix "machine-"
  @default_pending_days 7

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds manufacturing's reorganizer plan: one `:move` action per machine
  whose current folder does not already match the parent-folder hook,
  `:report` actions for folders that cannot be unambiguously resolved or
  would collide at apply time (`kind: :duplicate`), a folder the hook
  answered root for while it lives under a real parent (`kind: :hook_nil`,
  no move planned), a legacy-named folder found live somewhere else
  entirely (`kind: :relocated`), a hook that failed or is not callable
  (`kind: :hook_error`, no moves planned at all), `:trash`/`:report`
  actions for stale pending folders, and a `:report` (`kind: :orphan`) per
  legacy folder whose machine no longer exists.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is planned as `:trash` (or,
  without a configured hook, merely reported) instead of left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    machines = light_machines()

    # R1: independent of whether a hook is configured — a folder any live
    # machine's pointer names is never a pending-trash candidate.
    pointer_claims = live_pointer_claims(machines)

    {resource_actions, resolved_claims, resolved_parent, hook_on?} =
      case hook_status() do
        {:ok, mod, fun} ->
          {actions, claims, parent} =
            build_resource_plan(machines, actor_uuid, pointer_claims, mod, fun)

          {actions, claims, parent, true}

        {:not_callable, config} ->
          # U8: candidate detection touches no hook (it is pure local
          # lookups — F4/R8's "no hook call without a candidate" is about
          # the HOST's hook, never called here), so the report can still
          # name which machines are affected instead of a bare count.
          {candidates, _by_pointer, _by_name} = detect_candidates(machines)

          {[not_callable_hook_action(config, candidates)], claimed_folder_uuids([], [], [], []),
           nil, false}

        :none ->
          {[], claimed_folder_uuids([], [], [], []), nil, false}
      end

    claimed_uuids = MapSet.union(pointer_claims, resolved_claims)

    resource_actions ++
      orphan_actions(resolved_parent, claimed_uuids) ++
      pending_folder_actions(pending_days, claimed_uuids, hook_on?)
  end

  # ── Machines ─────────────────────────────────────────────────────

  # T3: a configured `{mod, fun}` that is not actually callable (a typo, a
  # removed function) is a distinct failure from "no hook configured at
  # all" — it must not silently degrade to report-only (E1) without
  # telling the owner why nothing moved. Returns the resolved `{mod, fun}`
  # alongside `:ok` so the caller never has to read the same env var again
  # to find out what to actually call (N8). V3/U7: ANY configured value
  # that is not a `{mod, fun}` naming a callable function — a typo'd tuple
  # or outright garbage (a string, a 3-tuple, …) — is the very same
  # misconfiguration and gets the very same `:hook_error`; only a genuinely
  # unset key (`nil`, the default) means "no hook".
  defp hook_status do
    case Application.get_env(:phoenix_kit_manufacturing, :attachments_parent_folder) do
      nil ->
        :none

      {mod, fun} = config when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: {:ok, mod, fun}, else: {:not_callable, config}

      other ->
        {:not_callable, other}
    end
  end

  defp callable?(mod, fun), do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2)

  # U8: names up to 10 affected machines instead of a bare count, so the
  # owner knows where to look.
  defp not_callable_hook_action(config, candidates) do
    labels = Enum.map(candidates, & &1.record.name)

    %{
      source: "manufacturing",
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason:
        "configured parent hook #{inspect(config)} is not callable or not a valid " <>
          "{module, function} config" <> label_suffix(labels)
    }
  end

  # U8: renders up to 10 record labels, then "… and N more" — used by every
  # `:hook_error`/`:hook_nil` report.
  defp label_suffix([]), do: ""

  defp label_suffix(labels) do
    {shown, rest} = Enum.split(labels, 10)
    more = length(rest)
    tail = if more > 0, do: " … and #{more} more", else: ""

    " — " <> Enum.join(shown, ", ") <> tail
  end

  # Candidate detection needs no hook call: a live pointer (uuid lookup) or
  # a live folder anywhere named after the machine's legacy name. The
  # parent hook — a single value shared by every machine, see moduledoc —
  # runs at most once, and only when at least one machine is a candidate
  # (F4/R8: no hook call without a candidate, even to widen orphan
  # detection — see `plan/2`, which falls back to a root-only orphan scan
  # when there is nothing for the hook to place).
  defp build_resource_plan(machines, actor_uuid, pointer_claims, mod, fun) do
    case detect_candidates(machines) do
      {[], _by_pointer, _by_name} ->
        # F4/R8: no hook call without a candidate — orphan detection falls
        # back to root scope only (see `orphan_actions/2` with `nil`).
        {[], claimed_folder_uuids([], [], [], []), nil}

      {candidates, by_pointer, by_name} ->
        resolve_and_build(candidates, by_pointer, by_name, mod, fun, actor_uuid, pointer_claims)
    end
  end

  # Pure local lookups — never calls the host's hook (F4/R8 is about
  # avoiding THAT call, not this one), so it is safe to run even when the
  # configured hook turns out to be uncallable, just to name the affected
  # machines in that report (U8).
  defp detect_candidates(machines) do
    prelim =
      Enum.map(machines, fn {machine, pointer} ->
        {:ok, legacy_name} = Attachments.folder_name_for(machine)

        %{
          record: machine,
          pointer: valid_uuid(pointer),
          legacy_name: legacy_name
        }
      end)

    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    candidates =
      Enum.filter(prelim, fn p ->
        (p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
          Map.has_key?(by_name, p.legacy_name)
      end)

    {candidates, by_pointer, by_name}
  end

  # R2: resolves the single shared parent via the host's exact hook,
  # distinguishing an explicit `nil` (root) from a hook that
  # raised/exited/returned anything else (failure — every candidate is
  # skipped, never treated as "root").
  defp resolve_and_build(candidates, by_pointer, by_name, mod, fun, actor_uuid, pointer_claims) do
    case resolve_parent(mod, fun, actor_uuid) do
      {:ok, parent_uuid} ->
        entries =
          candidates
          |> Enum.map(&resolve_entry(&1, parent_uuid, by_pointer, by_name))
          |> Enum.map(&apply_nil_root_guard/1)

        hook_nil_entries = Enum.filter(entries, & &1.hook_nil)

        {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
        {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

        {shared, unique} = split_shared(with_folder)

        # E3/F6: convergence collisions are only meaningful among entries
        # that actually need to move — a folder already sitting exactly
        # where it belongs (`noop_move?`) can never collide with anything
        # at apply time, so it must never be swept into a `:duplicate`
        # report merely for sharing its resolved name with a real mover.
        {movers, _noops} =
          Enum.split_with(unique, &(!noop_move?(&1.folder, &1.parent_uuid, &1.name)))

        {converging, _solo_movers} = split_converging(movers)

        converging_record_uuids =
          converging |> List.flatten() |> MapSet.new(& &1.record.uuid)

        move_actions =
          unique
          |> Enum.reject(&MapSet.member?(converging_record_uuids, &1.record.uuid))
          |> Enum.map(&build_move_action/1)
          |> Enum.reject(&is_nil/1)

        dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
        shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
        converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)

        claimed = claimed_folder_uuids(unique, ambiguous, shared, converging)
        all_claimed = MapSet.union(claimed, pointer_claims)

        # F5/T5: every live legacy-named copy other than the machine's
        # adopted current folder (if any) gets its own `:relocated` report
        # — except a copy that is itself another live machine's claimed
        # (adopted or pointer) folder, which is never also `:relocated`.
        # U9: `ambiguous` entries are included too — the two folders named
        # in their `:duplicate` report are excluded via `claimed`, but any
        # THIRD live copy is still a genuine stray and gets named here.
        stray_actions =
          stray_relocated_actions(with_folder ++ without_folder ++ ambiguous, all_claimed)

        hook_nil_actions = hook_nil_action(hook_nil_entries)

        all_actions =
          move_actions ++
            dup_actions ++
            shared_actions ++ converging_actions ++ stray_actions ++ hook_nil_actions

        {finalize_counts(all_actions), claimed, parent_uuid}

      :error ->
        {hook_error_action(candidates), claimed_folder_uuids([], [], [], []), nil}
    end
  end

  defp resolve_parent(mod, fun, actor_uuid) do
    guarded_hook_call(mod, fun, fn -> apply(mod, fun, ["machine", actor_uuid]) end)
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` (which also
  # normalises case) — `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook
  # FAILURES (`:error`), never sent into a later `in ^uuids` query (which
  # would raise a CastError and take down the whole plan). F2: an explicit
  # `{:ok, nil}` or bare `nil` means root. U6: every log line carries the
  # `{mod, fun}` that was called and the kind ("machine" — the only kind
  # this module ever asks the hook about) — including a bad-but-non-raising
  # return value, which used to fail silently.
  defp guarded_hook_call(mod, fun, thunk) do
    case thunk.() do
      {:ok, uuid} when is_binary(uuid) ->
        case valid_uuid(uuid) do
          nil ->
            log_bad_hook_return(mod, fun, {:ok, uuid})
            :error

          cast ->
            {:ok, cast}
        end

      {:ok, nil} ->
        {:ok, nil}

      nil ->
        {:ok, nil}

      other ->
        log_bad_hook_return(mod, fun, other)
        :error
    end
  rescue
    error ->
      Logger.warning(
        "Attachments parent hook #{inspect(mod)}.#{fun} (machine) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    kind, reason ->
      Logger.warning(
        "Attachments parent hook #{inspect(mod)}.#{fun} (machine) #{kind}: #{inspect(reason)}"
      )

      :error
  end

  defp log_bad_hook_return(mod, fun, value) do
    Logger.warning(
      "Attachments parent hook #{inspect(mod)}.#{fun} (machine) returned an unexpected " <>
        "value: #{inspect(value)}"
    )
  end

  # T4: always reported when the hook was actually called and failed —
  # even when the failure's only effect is that orphan detection got
  # skipped (F4/R8 guarantees `candidates` is never empty here). U8: names
  # up to 10 of the skipped machines.
  defp hook_error_action(candidates) do
    count = length(candidates)
    labels = Enum.map(candidates, & &1.record.name)

    [
      %{
        source: "manufacturing",
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{count} machine(s) skipped: the configured parent hook raised, exited, or " <>
            "returned neither {:ok, uuid} nor nil" <> label_suffix(labels)
      }
    ]
  end

  # F1: one report, not one per machine — mirrors `hook_error_action/1`.
  # U8: names up to 10 of the affected machines.
  defp hook_nil_action([]), do: []

  defp hook_nil_action(entries) do
    count = length(entries)
    labels = Enum.map(entries, & &1.record.name)

    [
      %{
        source: "manufacturing",
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{count} machine(s): the parent hook answered root for a folder living under a " <>
            "parent — left in place" <> label_suffix(labels)
      }
    ]
  end

  # Resolves one machine's current folder. `:pointer` when its live pointer
  # names a folder (kept as-is downstream — D6: never renamed, `name: nil`).
  # Otherwise the legacy name is looked up under the resolved parent and at
  # root (module's own order — `Attachments.find_folder_by_name/2` checks
  # parent first, root second); a live match at both is ambiguous. F5: every
  # OTHER live match for the legacy name (anywhere) is kept as
  # `stray_legacy` — including when neither the parent nor root matched at
  # all (N2: previously dropped silently, now every one of them is reported
  # `:relocated`).
  defp resolve_entry(p, parent_uuid, by_pointer, by_name) do
    pointer_folder = p.pointer && Map.get(by_pointer, p.pointer)

    if pointer_folder do
      matches = Map.get(by_name, p.legacy_name, [])
      stray = Enum.reject(matches, &(&1.uuid == pointer_folder.uuid))

      Map.merge(p, %{
        folder: pointer_folder,
        parent_uuid: parent_uuid,
        name: nil,
        via: :pointer,
        ambiguous: nil,
        stray_legacy: stray
      })
    else
      matches = Map.get(by_name, p.legacy_name, [])
      under_parent = parent_uuid && Enum.find(matches, &(&1.parent_uuid == parent_uuid))
      at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

      # U1/F1: the hook answered root (`parent_uuid` is `nil`), but a
      # legacy folder is already live under a genuine (non-root) parent
      # that nobody's hook call named — F1 forbids treating a nil answer
      # as grounds to move (or report as relocated) a folder that already
      # lives under a real parent. Adopted only when it is the SINGLE such
      # match; two or more real-parent matches (or one plus an at-root
      # match) are left ambiguous/relocated exactly as before — nothing
      # here can tell which one the hook actually meant.
      elsewhere_real_parent =
        if is_nil(parent_uuid), do: single_real_parent_match(matches, at_root)

      resolve_name_entry(p, parent_uuid, matches, under_parent || elsewhere_real_parent, at_root)
    end
  end

  defp single_real_parent_match(matches, at_root) do
    case Enum.reject(matches, &(&1 == at_root or is_nil(&1.parent_uuid))) do
      [only] -> only
      _ -> nil
    end
  end

  defp resolve_name_entry(p, parent_uuid, matches, under_parent, at_root)
       when not is_nil(under_parent) and not is_nil(at_root) do
    # U9: the ambiguous pair (`under_parent`/`at_root`) is reported as one
    # `:duplicate` action, but any THIRD live copy of the same legacy name
    # is still a genuine stray — kept here so it is reported `:relocated`
    # on its own instead of being silently zeroed out.
    stray = Enum.reject(matches, &(&1 == under_parent or &1 == at_root))

    Map.merge(p, %{
      folder: nil,
      parent_uuid: parent_uuid,
      name: p.legacy_name,
      via: nil,
      ambiguous: {under_parent, at_root},
      stray_legacy: stray
    })
  end

  defp resolve_name_entry(p, parent_uuid, matches, under_parent, at_root) do
    folder = under_parent || at_root
    stray = Enum.reject(matches, &(&1 == folder))

    Map.merge(p, %{
      folder: folder,
      parent_uuid: parent_uuid,
      name: p.legacy_name,
      via: folder && :name,
      ambiguous: nil,
      stray_legacy: stray
    })
  end

  # F1: an explicit `nil`/`{:ok, nil}` answer from the parent hook never
  # pulls a folder that currently lives under a real parent out to root —
  # only a pointer back-fill (if any) is kept; the parent and name stay
  # exactly as they are. U1: this already covers the name track too —
  # `resolve_entry/4` only ever sets `entry.folder` to a folder under a
  # real parent there (via `elsewhere_real_parent`) when the hook itself
  # answered root, so the same guard clause applies unchanged.
  defp apply_nil_root_guard(%{folder: %Folder{parent_uuid: parent_uuid}} = entry)
       when not is_nil(parent_uuid) and is_nil(entry.parent_uuid) do
    entry
    |> Map.put(:parent_uuid, parent_uuid)
    |> Map.put(:name, nil)
    |> Map.put(:hook_nil, true)
  end

  defp apply_nil_root_guard(entry), do: Map.put(entry, :hook_nil, false)

  # F5/T5: a live legacy-named copy of a machine other than its adopted
  # current folder — one `:relocated` report per copy, all of them, never
  # just the first. A copy that is itself claimed by another live machine
  # (its own resolved current folder, or a pointer claim) is excluded — a
  # claimed folder is never also reported `:relocated`. U3: batched over
  # the whole plan so naming a stray copy's actual (third-party) parent in
  # the reason never costs a query per copy.
  defp stray_relocated_actions(entries, claimed) do
    pairs =
      Enum.flat_map(entries, fn entry ->
        entry.stray_legacy
        |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
        |> Enum.map(&{entry, &1})
      end)

    parent_names = load_stray_parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      build_relocated_action(%{
        record: entry.record,
        relocated: folder,
        target_parent_uuid: entry.parent_uuid,
        parent_names: parent_names
      })
    end)
  end

  # Only parents that are neither root nor the machine's own resolved
  # target need a name — those two cases have their own fixed wording.
  defp load_stray_parent_names(pairs) do
    uuids =
      pairs
      |> Enum.map(fn {entry, folder} -> other_parent_uuid(folder, entry.parent_uuid) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids)
        |> order_by([f], asc: f.uuid)
        |> select([f], {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp other_parent_uuid(%Folder{parent_uuid: nil}, _target_parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, _target_parent_uuid), do: parent_uuid

  # Splits entries whose current folder is claimed by exactly one machine
  # (`unique`) from those where two or more machines resolve to the very
  # same live folder (`shared`, X5) — order-preserving (a plain `group_by`
  # would scramble R10's enumeration order): `unique`/`shared_entries` keep
  # `entries`' order via `split_with`, and `shared_groups` keeps it via
  # `group_preserving_order/2` (T6 — `Enum.group_by/2`'s `Map.values/1` is
  # ordered by key, not by first appearance).
  defp split_shared(entries) do
    freq = Enum.frequencies_by(entries, & &1.folder.uuid)
    {shared_entries, unique} = Enum.split_with(entries, &(Map.get(freq, &1.folder.uuid) > 1))
    shared_groups = group_preserving_order(shared_entries, & &1.folder.uuid)
    {shared_groups, unique}
  end

  # E3/F6: two (or more) machines whose *desired* target (resolved parent +
  # the kept/desired name) coincide — the second move would collide with
  # the first at apply time. Only considered among real move candidates
  # (`unique`, after ambiguous/shared are already split out) — computed
  # with a working hook, since `parent_uuid` here is always the hook's
  # resolved answer.
  defp split_converging(entries) do
    freq = Enum.frequencies_by(entries, &convergence_key/1)

    {converging_entries, solo} =
      Enum.split_with(entries, &(Map.get(freq, convergence_key(&1)) > 1))

    converging_groups = group_preserving_order(converging_entries, &convergence_key/1)
    {converging_groups, solo}
  end

  defp convergence_key(entry), do: {entry.parent_uuid, entry.name || entry.folder.name}

  # T6: `Enum.group_by/2 |> Map.values/1` orders groups by Erlang term
  # order of the grouping key — for a `Folder.uuid` (UUIDv7, roughly
  # chronological) that is nearly `inserted_at` order in practice, but not
  # guaranteed, and for a `convergence_key/1` tuple (parent uuid, name) it
  # is not related to `entries`' order at all. Groups instead in the order
  # each key was first seen in `entries` — which is already the
  # deterministic `light_machines/0` order by the time this runs.
  defp group_preserving_order(entries, key_fun) do
    grouped = Enum.group_by(entries, key_fun)

    entries
    |> Enum.map(key_fun)
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(grouped, &1))
  end

  defp claimed_folder_uuids(unique, ambiguous, shared_groups, converging_groups) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.flat_map(shared_groups, fn [%{folder: f} | _] -> [f.uuid] end)

    converging_uuids =
      Enum.flat_map(converging_groups, fn group -> Enum.map(group, & &1.folder.uuid) end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids ++ converging_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` and
  # needs no pointer back-fill is a no-op — filtered out here before it ever
  # reaches the core engine. D6: a folder found through the machine's
  # pointer keeps `name: nil` (never renamed); only a folder found by legacy
  # name gets the desired name.
  defp build_move_action(entry) do
    after_move = after_move_fun(entry.record, entry.pointer, entry.folder)

    if noop_move?(entry.folder, entry.parent_uuid, entry.name) and is_nil(after_move) do
      nil
    else
      %{
        source: "manufacturing",
        kind: :machine,
        label: entry.record.name,
        op: :move,
        folder: entry.folder,
        parent_uuid: entry.parent_uuid,
        name: entry.name,
        counts: nil,
        on_conflict: :suffix,
        after_move: after_move
      }
    end
  end

  # `name: nil` (a pointer-found folder, D6) — this module never renames
  # it itself, so only the parent needs to match for the move to be a
  # no-op (the engine's `on_conflict: :suffix`, D3, can still append the
  # usual numeric suffix on a genuine name collision with another folder).
  defp noop_move?(%Folder{parent_uuid: parent_uuid}, parent_uuid, nil), do: true

  # A binary `name` only ever comes from the legacy-name track, whose folder
  # was looked up by that exact name — so an exact match is the only case.
  # No `"name (N)"` variant check: a live same-name folder under the target
  # would itself have been found by that lookup (ambiguous, not a move), and
  # a pointer-found folder the engine suffixed on collision is matched by
  # the `name: nil` clause above on the next plan.
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(_folder, _parent_uuid, _name), do: false

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

  defp build_converging_duplicate_action([entry | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")
    {parent_uuid, name} = convergence_key(entry)
    parent_label = parent_uuid || "root"

    %{
      source: "manufacturing",
      kind: :duplicate,
      label: labels,
      op: :report,
      counts: nil,
      reason:
        "multiple machines would move to the same destination (parent #{parent_label}, name #{name}): #{labels}"
    }
  end

  defp build_relocated_action(%{record: machine, relocated: folder} = ctx) do
    %{
      source: "manufacturing",
      kind: :relocated,
      op: :report,
      label: machine.name,
      folder: folder,
      counts: nil,
      reason:
        relocated_reason(
          folder,
          Map.get(ctx, :target_parent_uuid),
          Map.get(ctx, :parent_names, %{})
        )
    }
  end

  # U3: the reason names the copy's actual place — at the media root,
  # already under the very parent the machine is headed to (where an
  # eventual move will land next to it as a `"name (N)"` suffixed twin),
  # or by name under a genuine third-party parent — instead of a blanket
  # "under a different parent" that reads wrong for two of the three cases.
  defp relocated_reason(%Folder{parent_uuid: nil} = folder, _target_parent_uuid, _names) do
    "legacy folder #{folder.uuid} is live at the media root — left alone, never adopted"
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, parent_uuid, _names) do
    "legacy folder #{folder.uuid} is already live as a twin under the target parent " <>
      "— left alone; an eventual move there will collide, landing as \"name (N)\""
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, _target_parent_uuid, names) do
    parent_label = Map.get(names, parent_uuid, parent_uuid)

    "legacy folder #{folder.uuid} is live under #{parent_label} — left alone, never adopted"
  end

  # R5/X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query (which would raise a CastError).
  # Returns the CAST/downcased value — not the raw string — so an
  # upper-case pointer still matches the (lower-case) keys `by_pointer` and
  # the live-claims set are keyed by.
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
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
        |> order_by([f], asc: f.inserted_at, asc: f.uuid)
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, matching a live
  # folder ANYWHERE (any parent, including root) — grouped by name so more
  # than one live match (different parents) is visible to `resolve_entry/4`
  # (X11). Live only (X2 — the unique index is partial, a trashed twin must
  # not hide the live folder). T6: ordered so a name with more than one
  # live match is itself deterministic.
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> order_by([f], asc: f.inserted_at, asc: f.uuid)
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # R1: every valid, live pointer of every LIVE machine — independent of
  # whether a parent hook is configured. Used only to keep a claimed folder
  # out of the pending-trash sweep; never triggers a hook.
  defp live_pointer_claims(machines) do
    pointers =
      machines
      |> Enum.map(fn {_machine, pointer} -> valid_uuid(pointer) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    uuids =
      case pointers do
        [] ->
          []

        pointers ->
          Folder
          |> where([f], f.uuid in ^pointers and is_nil(f.trashed_at))
          |> order_by([f], asc: f.inserted_at, asc: f.uuid)
          |> select([f], f.uuid)
          |> repo().all()
      end

    MapSet.new(uuids)
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

  # Re-checks the machine under `FOR UPDATE` at apply time: hard-deleted
  # since the plan was built aborts the back-fill instead of pointing a
  # once-live-looking machine at a folder nobody will ever see again.
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

  # X4/R1: a folder any live machine currently points at is never
  # independently reported/trashed as a pending folder — its move (or
  # duplicate report) action, if any, already covers it, and `claimed`
  # includes the hook-independent pointer claims regardless of `hook_on?`.
  defp pending_folder_actions(pending_days, claimed_uuids, hook_on?) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@pending_prefix}%"))
      |> order_by([f], asc: f.inserted_at, asc: f.uuid)
      |> repo().all()
      |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))

    counts = counts_by_folder(Enum.map(folders, & &1.uuid))
    files_by_folder = pending_files_by_folder(Enum.map(folders, & &1.uuid))

    folders
    |> Enum.map(&pending_folder_action(&1, cutoff, counts, files_by_folder, hook_on?))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff, counts, files_by_folder, hook_on?) do
    case folder_counts(counts, folder.uuid) do
      {0, 0} ->
        if DateTime.compare(folder.inserted_at, cutoff) == :lt do
          pending_stale_action(folder, hook_on?)
        end

      {files, links} ->
        %{
          source: "manufacturing",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: "pending folder still has #{pending_reason(folder.uuid, files_by_folder)}"
        }
    end
  end

  # E1: without a configured hook, a stale empty pending folder is
  # reported, never trashed.
  defp pending_stale_action(folder, true) do
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

  defp pending_stale_action(folder, false) do
    %{
      source: "manufacturing",
      kind: :pending,
      label: folder.name,
      op: :report,
      folder: folder,
      counts: {0, 0},
      reason:
        "empty pending upload folder older than the retention window " <>
          "(no attachments hook configured — not trashed)"
    }
  end

  # R6: one batched query (home files + linked files) for every non-empty
  # pending folder in the batch — never a query per folder. The reason is
  # never empty — a folder whose only files are trashed says so explicitly
  # instead of rendering an empty file list.
  defp pending_files_by_folder(folder_uuids) do
    case folder_uuids do
      [] ->
        %{}

      uuids ->
        home_rows =
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> order_by([f], asc: f.inserted_at, asc: f.uuid)
          |> select([f], {f.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        linked_rows =
          FolderLink
          |> join(:inner, [l], f in PhoenixKit.Modules.Storage.File, on: f.uuid == l.file_uuid)
          |> where([l, _f], l.folder_uuid in ^uuids)
          |> order_by([l, f], asc: f.inserted_at, asc: f.uuid)
          |> select([l, f], {l.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        Enum.group_by(home_rows ++ linked_rows, fn {folder_uuid, _name, _status} ->
          folder_uuid
        end)
    end
  end

  defp pending_reason(folder_uuid, files_by_folder) do
    rows = Map.get(files_by_folder, folder_uuid, [])

    live_names =
      rows
      |> Enum.reject(fn {_f, _n, status} -> status == "trashed" end)
      |> Enum.map(&elem(&1, 1))

    case live_names do
      [] -> "#{length(rows)} trashed file(s)"
      names -> "files: #{Enum.join(names, ", ")}"
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`machine-<uuid>`) at the media root or under the
  # resolved parent, whose uuid no longer names a machine (hard-deleted —
  # Machines has no soft-delete, see moduledoc), is reported so a host can
  # collect it. Never `:move`d or `:trash`ed here — this module owns no
  # "orphans" container; a legacy folder claimed above (a live machine's
  # current folder, or named in a duplicate/shared/converging report) is
  # excluded (R4 — one folder gets at most one action).
  #
  # `resolved_parent` is `nil` in three cases, all scanning root only: no
  # hook is configured, no machine was a move candidate at all (F4/R8 — the
  # hook is never called just to widen this scan), or the hook failed
  # (bad config, raise/exit, or a bad return value) so the true parent is
  # unknown (V2/U4 — the scan scope is root plus every parent that came
  # from a SUCCESSFUL hook answer; a failed hook contributes no such
  # parent, so the scope stays root-only rather than skipping the scan).
  # The `:hook_error` report already explains why nothing moved.
  defp orphan_actions(resolved_parent, claimed_uuids) do
    case legacy_candidate_folders(resolved_parent, claimed_uuids) do
      [] ->
        []

      candidates ->
        existing = existing_machine_uuids(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _uuid} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, existing, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under the resolved
  # parent whose name starts with the machine legacy prefix, minus every
  # folder already claimed by a move/duplicate/pointer above (R4).
  defp legacy_candidate_folders(resolved_parent, claimed_uuids) do
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
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
    |> repo().all()
    |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))
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

  # One query, only the uuid column (R9) — an orphan report only needs to
  # know whether the machine still exists, never its other columns.
  defp existing_machine_uuids(candidates) do
    uuids = Enum.map(candidates, fn {_folder, uuid} -> uuid end)

    Machine
    |> where([m], m.uuid in ^uuids)
    |> order_by([m], asc: m.inserted_at, asc: m.uuid)
    |> select([m], m.uuid)
    |> repo().all()
    |> MapSet.new()
  end

  defp orphan_action({folder, uuid}, existing, counts) do
    if MapSet.member?(existing, uuid) do
      nil
    else
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
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> order_by([f], asc: f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> order_by([l], asc: l.folder_uuid)
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

  # R9/R10: only the columns a plan needs, ordered by `inserted_at`/`uuid`
  # — a deterministic, readable report order. T8: the pointer is extracted
  # via a jsonb fragment instead of selecting the whole (potentially
  # large, ever-growing) `data` column — a light row returns
  # `{struct, pointer_uuid_or_nil}`, mirroring the catalogue template's
  # `light_catalogues/0`.
  defp light_machines do
    Machine
    |> order_by([m], asc: m.inserted_at, asc: m.uuid)
    |> select([m], {
      struct(m, [:uuid, :name, :inserted_at]),
      fragment("?->>'files_folder_uuid'", m.data)
    })
    |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
