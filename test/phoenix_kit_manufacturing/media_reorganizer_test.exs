defmodule PhoenixKitManufacturing.MediaReorganizerTest do
  use PhoenixKitManufacturing.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKitManufacturing.Machines
  alias PhoenixKitManufacturing.MediaReorganizer

  defmodule Hook do
    def parent("machine", _actor), do: {:ok, Process.get(:target_folder)}
    def parent(_, _), do: nil
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
    # No `:attachments_folder_name` hook — the desired name always stays
    # the deterministic legacy name.
    assert action.name == "machine-#{machine.uuid}"
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

  test "only kind ever planned for resources is :machine" do
    machine = new_machine(%{name: "Press 12"})
    {:ok, target} = Storage.create_folder(%{name: "Machines"})
    {:ok, folder} = Storage.create_folder(%{name: "machine-#{machine.uuid}"})

    {:ok, _machine} =
      Machines.update_machine(machine, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    resource_actions = Enum.filter(actions, &(&1.source == "manufacturing" and &1.op == :move))
    assert Enum.all?(resource_actions, &(&1.kind == :machine))
  end

  describe "pending folders" do
    test "empty pending folder older than pending_days → op: :trash" do
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

      assert action.op == :trash
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
  end
end
