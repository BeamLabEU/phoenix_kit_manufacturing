defmodule PhoenixKitManufacturing.AttachmentsParentFolderTest do
  use PhoenixKitManufacturing.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitManufacturing.Attachments
  alias PhoenixKitManufacturing.Schemas.Machine

  defmodule Hook do
    def parent("machine", _actor), do: {:ok, Process.get(:machines_container)}
    def parent(_, _), do: nil
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

  test "find_folder_by_name checks parent then root" do
    {:ok, container} = Storage.create_folder(%{name: "Machines"})
    name = "machine-#{Ecto.UUID.generate()}"
    {:ok, at_root} = Storage.create_folder(%{name: name})
    assert %{uuid: uuid} = Attachments.find_folder_by_name(name, container.uuid)
    assert uuid == at_root.uuid
  end
end
