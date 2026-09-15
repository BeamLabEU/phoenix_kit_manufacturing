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

    # D1: a hook must be configured (even one that resolves to root) for
    # the Source to plan anything at all.
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

  describe "duplicate folders (X4/X5/X11)" do
    test "legacy folder live at both root and under the resolved parent → one duplicate report, no move" do
      machine = new_machine()
      {:ok, target} = Storage.create_folder(%{name: "Machines"})
      {:ok, at_root} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

      {:ok, _under_parent} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :machine and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == machine.name))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ at_root.uuid
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
      # this folder is still never trashed (or reported), even though D1
      # leaves every other kind of action unplanned without a hook.
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

    test "orphaned legacy folder under the resolved parent (machine hard-deleted) → reported (X13)" do
      machine = new_machine()
      {:ok, target} = Storage.create_folder(%{name: "Machines"})

      {:ok, folder} =
        Storage.create_folder(%{name: "machine-#{machine.uuid}", parent_uuid: target.uuid})

      {:ok, _} = Machines.delete_machine(machine)

      # No live machine remains to surface as a move candidate — the hook
      # must still run once (via the machine-prefix existence check) for
      # this orphan, now sitting under the configured parent, to be found.
      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "missing"
    end
  end
end
