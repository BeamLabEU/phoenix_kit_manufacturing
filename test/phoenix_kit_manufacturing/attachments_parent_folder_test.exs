defmodule PhoenixKitManufacturing.AttachmentsParentFolderTest do
  use PhoenixKitManufacturing.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitManufacturing.Attachments
  alias PhoenixKitManufacturing.Schemas.Machine

  defmodule Hook do
    def parent("machine", _actor), do: {:ok, Process.get(:machines_container)}
    def parent(_, _), do: nil

    # Per-user containers: no actor, no container.
    def per_user("machine", nil), do: nil
    def per_user("machine", _actor), do: {:ok, Process.get(:machines_container)}

    def raising(_, _), do: raise("boom")
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_manufacturing, :attachments_parent_folder)
    end)

    :ok
  end

  test "nil without config" do
    assert Attachments.parent_folder_uuid("machine", nil) == nil
  end

  test "hook resolves by scope string and by resource struct" do
    {:ok, container} = Storage.create_folder(%{name: "Machines"})
    Process.put(:machines_container, container.uuid)
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :parent})

    assert Attachments.parent_folder_uuid("machine", nil) == container.uuid

    assert Attachments.parent_folder_uuid(%Machine{uuid: Ecto.UUID.generate()}, nil) ==
             container.uuid

    assert Attachments.parent_folder_uuid("operation", nil) == nil
  end

  test "a raising hook degrades to the storage root" do
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :raising})

    assert Attachments.parent_folder_uuid("machine", Ecto.UUID.generate()) == nil
  end

  test "find_folder_by_name checks parent then root" do
    {:ok, container} = Storage.create_folder(%{name: "Machines"})
    name = "machine-#{Ecto.UUID.generate()}"
    {:ok, at_root} = Storage.create_folder(%{name: name})
    assert %{uuid: uuid} = Attachments.find_folder_by_name(name, container.uuid)
    assert uuid == at_root.uuid
  end

  test "find_folder_by_name prefers the parent when both exist" do
    {:ok, container} = Storage.create_folder(%{name: "Machines"})
    name = "machine-#{Ecto.UUID.generate()}"
    {:ok, _at_root} = Storage.create_folder(%{name: name})
    {:ok, under} = Storage.create_folder(%{name: name, parent_uuid: container.uuid})

    assert %{uuid: uuid} = Attachments.find_folder_by_name(name, container.uuid)
    assert uuid == under.uuid
  end

  test "renaming a pending folder keeps it under its parent" do
    {:ok, container} = Storage.create_folder(%{name: "Machines"})
    Process.put(:machines_container, container.uuid)
    # Resolves to nil at rename time (no actor there) — must not move the folder.
    Application.put_env(:phoenix_kit_manufacturing, :attachments_parent_folder, {Hook, :per_user})

    {:ok, pending} =
      Storage.create_folder(%{
        name: "machine-attachment-pending-#{Ecto.UUID.generate()}",
        parent_uuid: container.uuid
      })

    machine = %Machine{uuid: Ecto.UUID.generate()}
    assert :ok = Attachments.maybe_rename_pending_folder_for(pending.uuid, machine)

    renamed = Storage.get_folder(pending.uuid)
    assert renamed.name == "machine-#{machine.uuid}"
    assert renamed.parent_uuid == container.uuid
  end
end
