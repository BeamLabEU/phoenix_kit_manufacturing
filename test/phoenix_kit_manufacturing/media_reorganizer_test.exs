defmodule PhoenixKitManufacturing.MediaReorganizerTest do
  use PhoenixKitManufacturing.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKitManufacturing.Machines
  alias PhoenixKitManufacturing.MediaReorganizer

  defmodule Hook do
    def parent("machine", _actor), do: {:ok, Process.get(:target_folder)}
    def parent(_, _), do: nil
  end

  # Counts calls in the process dictionary — `parent_folder_uuid/2` always
  # runs synchronously in the calling (test) process, so this is a reliable
  # per-test call counter without extra process coordination.
  defmodule CountingHook do
    def parent("machine", _actor) do
      Process.put(:hook_call_count, Process.get(:hook_call_count, 0) + 1)
      {:ok, Process.get(:target_folder)}
    end
  end

  defmodule RaisingHook do
    def parent("machine", _actor), do: raise("boom")
  end

  defmodule ErrorHook do
    def parent("machine", _actor), do: {:error, :timeout}
  end

  defmodule EmptyStringHook do
    def parent("machine", _actor), do: {:ok, ""}
  end

  defmodule GarbageUuidHook do
    def parent("machine", _actor), do: {:ok, "not-a-uuid"}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_manufacturing, :attachments_parent_folder)
    end)

    {:ok, user_uuid: fixture_user_uuid()}
  end

  # A minimal `phoenix_kit_users` row so `Storage.create_file/1`'s
  # `user_uuid` FK has something to reference — same pattern as
  # `PhoenixKitCatalogue.MediaReorganizerTest`.
  defp fixture_user_uuid do
    uuid = UUIDv7.generate()
    email = "reorg-test-#{System.unique_integer([:positive])}@example.com"

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(uuid),
        email,
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    uuid
  end

  defp new_machine(attrs \\ %{}) do
    {:ok, machine} = Machines.create_machine(Map.merge(%{name: "CNC-01"}, attrs))
    machine
  end

  defp create_file(attrs) do
    {:ok, file} =
      Storage.create_file(
        Map.merge(
          %{
            original_file_name: "file.pdf",
            file_name: "file.pdf",
            mime_type: "application/pdf",
            file_type: "document",
            ext: "pdf",
            file_checksum: "checksum-#{System.unique_integer([:positive])}",
            user_file_checksum: "user-checksum-#{System.unique_integer([:positive])}",
            size: 10,
            status: "active"
          },
          attrs
        )
      )

    file
  end

  test "no hook configured, legacy folder at root, pointer set → nothing planned" do
    machine = new_machine()
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    {:ok, _machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :machine and &1.label == machine.name))
  end

  test "hook configured, legacy folder at root, pointer set → one move action (parent change only)" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    {:ok, machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine))

    assert action.source == "manufacturing"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    # D6: found via a live pointer → kept as-is, never renamed.
    assert is_nil(action.name)
    assert action.on_conflict == :suffix
    assert action.counts == {0, 0}
    assert action.label == machine.name
    # pointer already correct → no back-fill needed
    assert is_nil(action.after_move)
  end

  test "counts include a trashed file — the engine re-measures the same way at apply time", %{
    user_uuid: user_uuid
  } do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    {:ok, _machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

    create_file(%{
      status: "trashed",
      folder_uuid: folder.uuid,
      user_uuid: user_uuid,
      file_checksum: "trashed-checksum"
    })

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine))

    assert action.counts == {1, 0}
  end

  test "pointer missing (folder found by legacy name) → after_move back-fills it" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine))

    assert action.folder.uuid == folder.uuid
    assert is_function(action.after_move, 0)

    assert :ok = action.after_move.()

    reloaded = Machines.get_machine(machine.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
  end

  test "after_move back-fill merges into existing data instead of clobbering it" do
    machine = new_machine(%{name: "Press 12", data: %{"other_key" => "keep-me"}})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine))

    assert :ok = action.after_move.()

    reloaded = Machines.get_machine(machine.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
    assert reloaded.data["other_key"] == "keep-me"
  end

  test "pointer points at a trashed folder while a live legacy folder exists at root → the live one is used" do
    machine = new_machine()
    {:ok, trashed} = Storage.create_folder(%{name: "old-pointer-target"})
    {:ok, trashed} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    {:ok, machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => trashed.uuid}})

    # E1: a hook must be configured (even one that resolves to root) for a
    # `:move` to be planned at all — without it this Source only reports.
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine and &1.label == machine.name))

    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  test "folder already at the right parent but pointer missing → move action with after_move" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})

    {:ok, folder} =
      Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine and &1.label == machine.name))

    refute is_nil(action)
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == folder.name
    assert is_function(action.after_move, 0)
  end

  test "folder already at the right parent and pointer already correct → nothing planned" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})

    {:ok, folder} =
      Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

    {:ok, _machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :machine and &1.label == machine.name))
  end

  test "no folder at all → no action" do
    _machine = new_machine(%{name: "Ghost mill"})
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :machine and &1.label == "Ghost mill"))
  end

  test "an upper-case pointer still resolves to its (lower-case) live folder (R5)" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    {:ok, _machine} =
      Machines.update_machine(machine, %{
        data: %{"files_folder_uuid" => String.upcase(folder.uuid)}
      })

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine))

    refute is_nil(action)
    assert action.folder.uuid == folder.uuid
  end

  test "invalid pointer values ('' and 'not-a-uuid') are treated as absent, never raise" do
    m1 = new_machine(%{name: "A", data: %{"files_folder_uuid" => "not-a-uuid"}})
    m2 = new_machine(%{name: "B", data: %{"files_folder_uuid" => ""}})

    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, f1} = Storage.create_folder(%{name: "machine-#{m1.uuid}"})
    {:ok, f2} = Storage.create_folder(%{name: "machine-#{m2.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    a1 = Enum.find(actions, &(&1.kind == :machine and &1.label == m1.name))
    a2 = Enum.find(actions, &(&1.kind == :machine and &1.label == m2.name))

    refute is_nil(a1)
    refute is_nil(a2)
    assert a1.folder.uuid == f1.uuid
    assert a2.folder.uuid == f2.uuid
  end

  test "parent hook runs once for the whole plan, even with several move candidates" do
    m1 = new_machine(%{name: "A"})
    m2 = new_machine(%{name: "B"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, f1} = Storage.create_folder(%{name: "machine-#{m1.uuid}"})
    {:ok, f2} = Storage.create_folder(%{name: "machine-#{m2.uuid}"})

    {:ok, _m1} = Machines.update_machine(m1, %{data: %{"files_folder_uuid" => f1.uuid}})
    {:ok, _m2} = Machines.update_machine(m2, %{data: %{"files_folder_uuid" => f2.uuid}})

    Process.put(:target_folder, target.uuid)

    Application.put_env(
      :phoenix_kit_manufacturing,
      :attachments_parent_folder,
      {CountingHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    assert Enum.count(actions, &(&1.kind == :machine and &1.op == :move)) == 2
    assert Process.get(:hook_call_count) == 1
  end

  test "parent hook is never called when nothing machine-related exists to place" do
    Application.put_env(
      :phoenix_kit_manufacturing,
      :attachments_parent_folder,
      {CountingHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    assert actions == []
    assert Process.get(:hook_call_count, 0) == 0
  end

  test "hook raises → move candidates skipped, one hook_error report, never planned as root (R2)" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    Application.put_env(
      :phoenix_kit_manufacturing,
      :attachments_parent_folder,
      {RaisingHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    refute Enum.any?(actions, &(&1.kind == :machine))
    error = Enum.find(actions, &(&1.kind == :hook_error))
    refute is_nil(error)
    assert error.op == :report
    assert error.reason =~ "1 machine(s) skipped"

    # never silently treated as root: the folder isn't moved and isn't
    # reported as an orphan either (it's still a live machine's folder).
    refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
  end

  test "hook returns {:error, _} → same as raising, never treated as root (R2)" do
    m1 = new_machine(%{name: "A"})
    m2 = new_machine(%{name: "B"})
    {:ok, _f1} = Storage.create_folder(%{name: "machine-#{m1.uuid}"})
    {:ok, _f2} = Storage.create_folder(%{name: "machine-#{m2.uuid}"})

    Application.put_env(
      :phoenix_kit_manufacturing,
      :attachments_parent_folder,
      {ErrorHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    refute Enum.any?(actions, &(&1.kind == :machine))
    error = Enum.find(actions, &(&1.kind == :hook_error))
    refute is_nil(error)
    assert error.reason =~ "2 machine(s) skipped"
  end

  test "hook returns {:ok, \"\"} → treated as a hook failure, not root (R2)" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    Application.put_env(
      :phoenix_kit_manufacturing,
      :attachments_parent_folder,
      {EmptyStringHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    refute Enum.any?(actions, &(&1.kind == :machine))
    error = Enum.find(actions, &(&1.kind == :hook_error))
    refute is_nil(error)
    assert error.reason =~ "1 machine(s) skipped"
  end

  test "hook returns {:ok, \"not-a-uuid\"} → treated as a hook failure, not root (R2)" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    Application.put_env(
      :phoenix_kit_manufacturing,
      :attachments_parent_folder,
      {GarbageUuidHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    refute Enum.any?(actions, &(&1.kind == :machine))
    error = Enum.find(actions, &(&1.kind == :hook_error))
    refute is_nil(error)
    assert error.reason =~ "1 machine(s) skipped"
  end

  test "hook fails → orphan scan still covers root (V2/U4), alongside the hook_error report" do
    # A live machine so the hook actually runs and the hook_error report is
    # non-empty.
    machine = new_machine(%{name: "Press 12"})
    {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    # A genuine orphan at root: the scan scope is always root plus every
    # parent from a SUCCESSFUL hook answer — a failed hook contributes no
    # such parent, but root stays in scope regardless (V2/U4), so this is
    # still found and reported.
    ghost = new_machine()
    {:ok, orphan_folder} = Storage.create_folder(%{name: "machine-#{ghost.uuid}"})
    {:ok, _} = Machines.delete_machine(ghost)

    Application.put_env(
      :phoenix_kit_manufacturing,
      :attachments_parent_folder,
      {RaisingHook, :parent}
    )

    actions = MediaReorganizer.plan(nil, [])

    assert Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == orphan_folder.uuid))
    error = Enum.find(actions, &(&1.kind == :hook_error))
    refute is_nil(error)
  end

  describe "uncallable configured hook (T3)" do
    test "hook module/function does not exist → hook_error 'not callable', no moves, no crash" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {PhoenixKitManufacturing.MediaReorganizerTest.NoSuchModule, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not callable"
    end

    test "hook module exists but the configured function is not exported → hook_error 'not callable', no moves, no crash" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {Hook, :no_such_function}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not callable"
    end
  end

  describe "explicit nil from a hook never moves a folder out of its parent (F1)" do
    test "machine's pointer already names a folder under a parent, hook answers nil → no move, hook_nil report" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, folder} = Storage.create_folder(%{name: "Real folder", parent_uuid: target.uuid})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

      # `Hook.parent/2`'s default clause answers `nil` (root) because
      # `:target_folder` is never set for this test.
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(
               actions,
               &(&1.kind == :machine and &1.op == :move and &1.parent_uuid == nil)
             )

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.op == :report
      assert hook_nil.reason =~ "1 machine"

      # Pointer already matches `folder` — nothing left to plan once the
      # false move-to-root is suppressed.
      refute Enum.any?(actions, &(&1.kind == :machine))
    end

    test "the hook_nil report aggregates a count across every affected machine" do
      m1 = new_machine(%{name: "First"})
      m2 = new_machine(%{name: "Second"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, f1} = Storage.create_folder(%{name: "Real folder 1", parent_uuid: target.uuid})
      {:ok, f2} = Storage.create_folder(%{name: "Real folder 2", parent_uuid: target.uuid})

      {:ok, _m1} = Machines.update_machine(m1, %{data: %{"files_folder_uuid" => f1.uuid}})
      {:ok, _m2} = Machines.update_machine(m2, %{data: %{"files_folder_uuid" => f2.uuid}})

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "2 machine"
    end
  end

  describe "converging targets (E3/F6)" do
    test "two machines each keeping their own pointer-found folder name would collide at the same destination → duplicate, no moves" do
      m1 = new_machine(%{name: "First"})
      m2 = new_machine(%{name: "Second"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, other} = Storage.create_folder(%{name: "Other container"})
      {:ok, f1} = Storage.create_folder(%{name: "Docs"})
      {:ok, f2} = Storage.create_folder(%{name: "Docs", parent_uuid: other.uuid})

      {:ok, _m1} = Machines.update_machine(m1, %{data: %{"files_folder_uuid" => f1.uuid}})
      {:ok, _m2} = Machines.update_machine(m2, %{data: %{"files_folder_uuid" => f2.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))

      dup =
        Enum.find(
          actions,
          &(&1.kind == :duplicate and &1.label =~ "First" and &1.label =~ "Second")
        )

      refute is_nil(dup)
    end

    test "an already-placed machine never blocks a different machine's real move to the same name (E3/F6 excludes noops from convergence)" do
      already_placed = new_machine(%{name: "Already placed"})
      mover = new_machine(%{name: "Mover"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})

      # `already_placed`'s pointer folder is already named "Docs" directly
      # under the resolved target — a true no-op, zero action needed.
      {:ok, in_place} = Storage.create_folder(%{name: "Docs", parent_uuid: target.uuid})

      # `mover`'s pointer folder is also named "Docs", but lives elsewhere
      # and genuinely needs to move into the target — the engine's own
      # `on_conflict: :suffix` would resolve the name collision at apply
      # time since `already_placed` never moves.
      {:ok, to_move} = Storage.create_folder(%{name: "Docs", parent_uuid: elsewhere.uuid})

      {:ok, _} =
        Machines.update_machine(already_placed, %{data: %{"files_folder_uuid" => in_place.uuid}})

      {:ok, _} = Machines.update_machine(mover, %{data: %{"files_folder_uuid" => to_move.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :duplicate))

      move = Enum.find(actions, &(&1.kind == :machine and &1.op == :move))
      refute is_nil(move)
      assert move.label == mover.name
      assert move.folder.uuid == to_move.uuid
      assert move.parent_uuid == target.uuid

      # the already-placed machine needs no action of its own at all.
      refute Enum.any?(actions, &(&1.kind == :machine and &1.label == already_placed.name))
    end

    test "two machines resolving to different names never converge → both move independently" do
      m1 = new_machine(%{name: "First"})
      m2 = new_machine(%{name: "Second"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, f1} = Storage.create_folder(%{name: "machine-#{m1.uuid}"})
      {:ok, f2} = Storage.create_folder(%{name: "machine-#{m2.uuid}"})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :duplicate))
      assert Enum.count(actions, &(&1.kind == :machine and &1.op == :move)) == 2
      assert Enum.any?(actions, &(&1.kind == :machine and &1.folder.uuid == f1.uuid))
      assert Enum.any?(actions, &(&1.kind == :machine and &1.folder.uuid == f2.uuid))
    end
  end

  test "a legacy-named twin live elsewhere is reported :relocated alongside the pointer-found folder's own action" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, current} = Storage.create_folder(%{name: "Renamed by hand", parent_uuid: target.uuid})
    {:ok, twin} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    {:ok, machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => current.uuid}})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    relocated = Enum.find(actions, &(&1.kind == :relocated))
    refute is_nil(relocated)
    assert relocated.source == "manufacturing"
    assert relocated.op == :report
    assert relocated.label == machine.name
    assert relocated.folder.uuid == twin.uuid

    # the machine's own current folder already sits at the resolved parent
    # under its own (kept, not renamed) name — nothing else to move.
    refute Enum.any?(actions, &(&1.kind == :machine))

    # the twin is never also reported as an orphan (its machine is live).
    refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == twin.uuid))
  end

  test "legacy folder live under neither the resolved parent nor root, no pointer → reported :relocated, not silently dropped (N2)" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

    {:ok, legacy} =
      Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: elsewhere.uuid})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    refute Enum.any?(actions, &(&1.kind == :machine))
    relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == machine.name))
    refute is_nil(relocated)
    assert relocated.folder.uuid == legacy.uuid

    # never mistaken for an orphan — the machine is live, just not adopted.
    refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == legacy.uuid))
  end

  test "a stray legacy copy that is another machine's live pointer target is never reported :relocated (T5)" do
    a = new_machine(%{name: "A"})
    b = new_machine(%{name: "B"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

    {:ok, shared} =
      Storage.create_folder(%{name: "machine-#{a.uuid}", parent_uuid: elsewhere.uuid})

    {:ok, _b} = Machines.update_machine(b, %{data: %{"files_folder_uuid" => shared.uuid}})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    # `shared` is B's own live pointer folder — never also reported as a
    # stray copy of A's legacy name, and never an orphan either.
    refute Enum.any?(actions, &(&1.kind == :relocated and &1.folder.uuid == shared.uuid))
    refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == shared.uuid))
  end

  test "legacy folder a machine's pointer claims (under a different machine's stale name) is never also reported as an orphan (R4)" do
    ghost_uuid = Ecto.UUID.generate()
    machine = new_machine()

    {:ok, folder} = Storage.create_folder(%{name: "machine-#{ghost_uuid}"})

    {:ok, _machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
  end

  test "after_move back-fill on a hard-deleted machine aborts instead of writing a dangling pointer" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :machine))

    {:ok, _} = Machines.delete_machine(machine)

    assert action.after_move.() == {:error, :not_found}
    reloaded = Storage.get_folder(folder.uuid)
    refute is_nil(reloaded)
  end

  test "plan/2 never creates a folder" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    count_before = Repo.aggregate(Storage.Folder, :count)
    _actions = MediaReorganizer.plan(nil, [])
    count_after = Repo.aggregate(Storage.Folder, :count)

    assert count_before == count_after
  end

  describe "light select never pulls the jsonb data column (T8)" do
    test "the machines candidate-detection query selects the pointer via a jsonb fragment, not the raw data column" do
      machine = new_machine()
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:phoenix_kit_manufacturing, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          send(test_pid, {:query, ref, query})
        end,
        nil
      )

      try do
        MediaReorganizer.plan(nil, [])
      after
        :telemetry.detach({__MODULE__, ref})
      end

      queries = collect_queries(ref)

      machines_queries = Enum.filter(queries, &(&1 =~ "phoenix_kit_machines"))

      refute Enum.empty?(machines_queries)
      assert Enum.any?(machines_queries, &(&1 =~ "->>"))
      refute Enum.any?(machines_queries, &Regex.match?(~r/"data"(?!->)/, &1))
    end
  end

  defp collect_queries(ref) do
    receive do
      {:query, ^ref, query} -> [query | collect_queries(ref)]
    after
      0 -> []
    end
  end

  describe "duplicate folders (X4/X5/X11)" do
    test "legacy folder live at both root and under the resolved parent → one duplicate report, no move" do
      machine = new_machine()
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, at_root} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      {:ok, under_parent} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == machine.name))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ at_root.uuid
      assert dup.reason =~ under_parent.uuid
    end

    test "two machines whose current folder resolves to the same live folder → one duplicate report, no move" do
      m1 = new_machine(%{name: "First"})
      m2 = new_machine(%{name: "Second"})

      {:ok, shared} = Storage.create_folder(%{name: "shared-folder"})
      {:ok, m1} = Machines.update_machine(m1, %{data: %{"files_folder_uuid" => shared.uuid}})
      {:ok, m2} = Machines.update_machine(m2, %{data: %{"files_folder_uuid" => shared.uuid}})

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == shared.name))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ m1.name
      assert dup.reason =~ m2.name
    end
  end

  describe "pending folders" do
    test "empty pending folder older than pending_days, hook configured → op: :trash" do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :trash
    end

    test "empty pending folder older than pending_days, no hook configured → op: :report (E1)" do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :report
      assert action.reason =~ "no attachments hook configured"
    end

    test "non-empty pending folder → op: :report with the file name in the reason", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      create_file(%{
        original_file_name: "leftover.pdf",
        file_name: "leftover.pdf",
        folder_uuid: folder.uuid,
        user_uuid: user_uuid
      })

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :report
      assert action.reason =~ "leftover.pdf"
    end

    test "pending folder younger than pending_days → no action" do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end

    test "pending folder a live machine's pointer names is never trashed, even with no hook configured (R1)" do
      machine = new_machine()

      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      # No hook configured at all — R1's claims are hook-independent, so
      # this folder is still never trashed (or reported), even though E1
      # restricts every other action without a hook to report-only.
      actions = MediaReorganizer.plan(nil, pending_days: 7)

      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end

    test "an upper-case pointer to a pending folder claims it — never trashed (R5)" do
      machine = new_machine()

      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _machine} =
        Machines.update_machine(machine, %{
          data: %{"files_folder_uuid" => String.upcase(folder.uuid)}
        })

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      actions = MediaReorganizer.plan(nil, pending_days: 7)

      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end

    test "pending folder whose only file is trashed → reason says N trashed file(s), never empty (R6)",
         %{user_uuid: user_uuid} do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      create_file(%{
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: user_uuid,
        file_checksum: "trashed-pending-checksum"
      })

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "1 trashed file(s)"
    end

    test "pending folder a live machine currently points at is never independently reported/trashed (X4)" do
      machine = new_machine()

      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, pending_days: 7)

      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end

    test "pending folder with only a linked file (no direct File row) → report still names it", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, elsewhere} = Storage.create_folder(%{name: "elsewhere"})

      file =
        create_file(%{
          original_file_name: "linked.pdf",
          folder_uuid: elsewhere.uuid,
          user_uuid: user_uuid
        })

      {:ok, _link} =
        %FolderLink{}
        |> FolderLink.changeset(%{folder_uuid: folder.uuid, file_uuid: file.uuid})
        |> Repo.insert()

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.counts == {0, 1}
      assert action.reason =~ "linked.pdf"
    end
  end

  describe "deterministic report ordering (T6)" do
    test "orphan reports are ordered by inserted_at, not by row/insertion order" do
      older_uuid = Ecto.UUID.generate()
      newer_uuid = Ecto.UUID.generate()

      # Created in the opposite order from the `inserted_at` values they
      # are backdated to below, so a query with no `order_by` (row/scan
      # order) would list them newer-first — the reverse of the assertion.
      {:ok, newer} = Storage.create_folder(%{name: "machine-#{newer_uuid}"})
      {:ok, older} = Storage.create_folder(%{name: "machine-#{older_uuid}"})

      older_time =
        DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)

      newer_time =
        DateTime.utc_now() |> DateTime.add(-1 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^older.uuid),
        set: [inserted_at: older_time]
      )

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^newer.uuid),
        set: [inserted_at: newer_time]
      )

      actions = MediaReorganizer.plan(nil, [])

      orphan_uuids =
        actions
        |> Enum.filter(&(&1.kind == :orphan))
        |> Enum.map(& &1.folder.uuid)

      assert orphan_uuids == [older.uuid, newer.uuid]
    end

    test "pending folder's file list is ordered by inserted_at, not by row/insertion order", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      # Created in the opposite order from the `inserted_at` values they
      # are backdated to below, so a query with no `order_by` (row/scan
      # order) would list them newer-first — the reverse of the assertion.
      newer_file =
        create_file(%{
          original_file_name: "newer.pdf",
          folder_uuid: folder.uuid,
          user_uuid: user_uuid
        })

      older_file =
        create_file(%{
          original_file_name: "older.pdf",
          folder_uuid: folder.uuid,
          user_uuid: user_uuid
        })

      older_time =
        DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.truncate(:second)

      newer_time =
        DateTime.utc_now() |> DateTime.add(-1 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in PhoenixKit.Modules.Storage.File, where: f.uuid == ^older_file.uuid),
        set: [inserted_at: older_time]
      )

      Repo.update_all(
        from(f in PhoenixKit.Modules.Storage.File, where: f.uuid == ^newer_file.uuid),
        set: [inserted_at: newer_time]
      )

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      refute is_nil(action)

      names_index = fn name -> :binary.match(action.reason, name) |> elem(0) end
      assert names_index.("older.pdf") < names_index.("newer.pdf")
    end
  end

  describe "orphan folders" do
    test "legacy folder with no matching machine → orphan report with counts", %{
      user_uuid: user_uuid
    } do
      {:ok, folder} = Storage.create_folder(%{name: "machine-#{Ecto.UUID.generate()}"})

      create_file(%{
        original_file_name: "stray.pdf",
        folder_uuid: folder.uuid,
        user_uuid: user_uuid
      })

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "manufacturing"
      assert action.op == :report
      assert action.counts == {1, 0}
      assert action.reason =~ "missing"
      assert action.reason =~ "1 file"
    end

    test "hard-deleted machine's legacy folder → reported as orphan (no soft-delete status to check)" do
      machine = new_machine()
      {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})
      {:ok, _} = Machines.delete_machine(machine)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "missing"
    end

    test "legacy folder of a live machine → not reported as orphan" do
      machine = new_machine()
      {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "legacy folder of a machine with a non-active lifecycle status → not reported as orphan (still a live record)" do
      machine = new_machine(%{status: "decommissioned"})
      {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    # F4/R8: R8 wins over X13 — no hook call without a move candidate, so
    # an orphan under a parent no candidate resolved is never found (only
    # at root, see the test above); calling the hook just to widen an
    # orphan scan is no longer done (an Andi `Containers.ensure`-style
    # hook would create a container and write Settings on a dry-run plan).
    test "orphaned legacy folder under a non-root parent, no live move candidate → NOT reported (hook never called, F4/R8)" do
      machine = new_machine()
      {:ok, target} = Storage.create_folder(%{name: "Machines"})

      {:ok, folder} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      {:ok, _} = Machines.delete_machine(machine)

      Process.put(:target_folder, target.uuid)

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {CountingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
      assert Process.get(:hook_call_count, 0) == 0
    end
  end

  describe "F1 on the name track (U1)" do
    test "no pointer, legacy folder under a real parent, hook answers root → adopted as the current folder, back-fill only, hook_nil (no :relocated)" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})

      {:ok, legacy} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      # `Hook.parent/2`'s default clause answers `nil` (root) because
      # `:target_folder` is never set for this test.
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :relocated and &1.folder.uuid == legacy.uuid))

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "1 machine"
      assert hook_nil.reason =~ machine.name

      action = Enum.find(actions, &(&1.kind == :machine))
      refute is_nil(action)
      assert action.op == :move
      assert action.folder.uuid == legacy.uuid
      assert action.parent_uuid == target.uuid
      assert action.name == nil
      assert is_function(action.after_move, 0)

      assert :ok = action.after_move.()
      reloaded = Machines.get_machine(machine.uuid)
      assert reloaded.data["files_folder_uuid"] == legacy.uuid

      # never mistaken for an orphan — the machine is live and the folder
      # is adopted, not abandoned.
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == legacy.uuid))
    end

    test "legacy folder under a real parent AND a live copy at root, hook answers root → ambiguous, not silently adopted" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})

      {:ok, under_parent} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      {:ok, at_root} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine))
      refute Enum.any?(actions, &(&1.kind == :hook_nil))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == machine.name))
      refute is_nil(dup)
      assert dup.reason =~ under_parent.uuid
      assert dup.reason =~ at_root.uuid
    end

    test "two legacy copies under two different real parents, hook answers root → left unresolved, each reported :relocated" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, parent_a} = Storage.create_folder(%{name: "Building A"})
      {:ok, parent_b} = Storage.create_folder(%{name: "Building B"})

      {:ok, copy_a} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: parent_a.uuid})

      {:ok, copy_b} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: parent_b.uuid})

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine))
      refute Enum.any?(actions, &(&1.kind == :hook_nil))

      relocated = Enum.filter(actions, &(&1.kind == :relocated))
      assert length(relocated) == 2
      assert Enum.any?(relocated, &(&1.folder.uuid == copy_a.uuid))
      assert Enum.any?(relocated, &(&1.folder.uuid == copy_b.uuid))
    end
  end

  describe "the ambiguous branch keeps every extra copy for :relocated (U9)" do
    test "three live copies of the same legacy name (root, under target, and elsewhere) → the third is named too" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

      {:ok, at_root} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      {:ok, under_target} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      {:ok, third} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == machine.name))
      refute is_nil(dup)
      assert dup.reason =~ at_root.uuid
      assert dup.reason =~ under_target.uuid

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == third.uuid))
      refute is_nil(relocated)
      assert relocated.label == machine.name

      # the third copy is never also reported as an orphan.
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == third.uuid))
    end
  end

  describe "relocated reason names the place (U3)" do
    test "stray copy live at the media root" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, current} = Storage.create_folder(%{name: "Renamed by hand", parent_uuid: target.uuid})
      {:ok, twin} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => current.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin.uuid))
      refute is_nil(relocated)
      assert relocated.reason =~ "media root"
    end

    test "stray copy already live under the target parent (twin) — landing collision named" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, current} = Storage.create_folder(%{name: "Renamed by hand", parent_uuid: target.uuid})

      {:ok, twin} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => current.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin.uuid))
      refute is_nil(relocated)
      assert relocated.reason =~ "target parent"
      assert relocated.reason =~ "twin"
    end

    test "stray copy live under a genuine third-party parent — named" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, other} = Storage.create_folder(%{name: "Warehouse annex"})
      {:ok, current} = Storage.create_folder(%{name: "Renamed by hand", parent_uuid: target.uuid})

      {:ok, twin} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: other.uuid})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => current.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == twin.uuid))
      refute is_nil(relocated)
      assert relocated.reason =~ "Warehouse annex"
    end
  end

  describe "invalid hook config is a hook_error, never silent no-hook (V3/U7)" do
    test "a non-tuple garbage config → hook_error 'not callable', no moves" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, "garbage")

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not callable"
    end

    test "a 3-tuple config → hook_error 'not callable', no moves" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {Hook, :parent, :extra}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not callable"
    end

    test "no key configured at all → no report, plan proceeds (report-only for pending/orphans)" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_error))
    end
  end

  describe "hook_error / hook_nil reports name the affected machines (U8)" do
    test "an uncallable hook config names the affected machine" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, "garbage")

      actions = MediaReorganizer.plan(nil, [])

      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ machine.name
    end

    test "a runtime hook failure names every skipped machine" do
      m1 = new_machine(%{name: "First"})
      m2 = new_machine(%{name: "Second"})
      {:ok, _f1} = Storage.create_folder(%{name: "machine-#{m1.uuid}"})
      {:ok, _f2} = Storage.create_folder(%{name: "machine-#{m2.uuid}"})

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ m1.name
      assert error.reason =~ m2.name
    end

    test "more than 10 skipped machines → the reason lists 10 and says how many more" do
      machines =
        for i <- 1..12 do
          # zero-padded so no name is a text substring of another (e.g.
          # "Machine 01" vs "Machine 10").
          m = new_machine(%{name: "Machine #{String.pad_leading(to_string(i), 2, "0")}"})
          {:ok, _folder} = Storage.create_folder(%{name: "machine-#{m.uuid}"})
          m
        end

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "and 2 more"

      # order between same-millisecond UUIDv7 rows isn't guaranteed to match
      # creation order, so only the count of named machines is asserted,
      # not which specific 10 of the 12 are named.
      named_count = Enum.count(machines, &(error.reason =~ &1.name))
      assert named_count == 10
    end

    test "a hook_nil report names the affected machine" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, folder} = Storage.create_folder(%{name: "Real folder", parent_uuid: target.uuid})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ machine.name
    end
  end

  describe "hook log lines carry {mod, fun} and the kind (U6)" do
    test "a raising hook logs the configured module/function and the machine kind" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          MediaReorganizer.plan(nil, [])
        end)

      assert log =~ "RaisingHook"
      assert log =~ "parent"
      assert log =~ "machine"
    end

    test "a hook returning a bad-but-non-raising value is logged too" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, _folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      Application.put_env(
        :phoenix_kit_manufacturing,
        :attachments_parent_folder,
        {ErrorHook, :parent}
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          MediaReorganizer.plan(nil, [])
        end)

      assert log =~ "ErrorHook"
      assert log =~ "unexpected"
    end
  end

  # Everything above asserts the plan maps in isolation. These run the plan
  # through core's real engine (`Action.new!/1` normalization, `noop?/1`,
  # and `apply_one/1`), so a shape drift between this Source and the engine
  # — or a plan that doesn't converge once applied — fails here.
  describe "through the core engine" do
    alias PhoenixKit.Modules.Storage.Reorganizer

    defp engine_run(apply?) do
      {:ok, report} =
        Reorganizer.run(nil, sources: [MediaReorganizer], apply?: apply?, pending_days: 7)

      report.actions
    end

    test "legacy folder at root, no pointer → moved under the hook's parent and pointer back-filled, then converges" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      {:ok, machine} =
        Machines.update_machine(machine, %{data: %{"featured_image_uuid" => "keep-me"}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      [action] = Enum.filter(engine_run(true), &(&1.kind == :machine))
      assert action.outcome in [:moved, :backfilled]

      moved = Storage.get_folder(folder.uuid)
      assert moved.parent_uuid == target.uuid
      assert moved.name == "machine-#{machine.uuid}"

      reloaded = Machines.get_machine(machine.uuid)
      assert reloaded.data["files_folder_uuid"] == folder.uuid
      assert reloaded.data["featured_image_uuid"] == "keep-me"

      assert engine_run(false) |> Enum.filter(&(&1.source == "manufacturing")) == []
    end

    test "pointer folder colliding with a same-name folder under the target lands suffixed, then converges" do
      machine = new_machine(%{name: "Press 12"})
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, _other} = Storage.create_folder(%{name: "Drawings", parent_uuid: target.uuid})
      {:ok, folder} = Storage.create_folder(%{name: "Drawings"})

      {:ok, _machine} =
        Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      [action] = Enum.filter(engine_run(true), &(&1.kind == :machine))
      assert action.outcome == :moved_renamed

      moved = Storage.get_folder(folder.uuid)
      assert moved.parent_uuid == target.uuid
      assert moved.name == "Drawings (2)"

      assert engine_run(false) |> Enum.filter(&(&1.source == "manufacturing")) == []
    end

    test "stale empty pending folder is trashed on apply" do
      {:ok, folder} =
        Storage.create_folder(%{name: "machine-attachment-pending-#{Ecto.UUID.generate()}"})

      old =
        DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old]
      )

      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      action = Enum.find(engine_run(true), &(&1.kind == :pending))
      assert action.outcome == :trashed
      assert Storage.get_folder(folder.uuid).trashed_at
    end
  end
end
