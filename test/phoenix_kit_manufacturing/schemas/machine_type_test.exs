defmodule PhoenixKitManufacturing.Schemas.MachineTypeTest do
  use ExUnit.Case, async: true

  alias PhoenixKitManufacturing.Schemas.MachineType

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "is valid with just a name" do
      changeset = MachineType.changeset(%MachineType{}, %{name: "CNC"})
      assert changeset.valid?
    end

    test "requires a name" do
      changeset = MachineType.changeset(%MachineType{}, %{description: "no name"})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "only allows active/inactive statuses" do
      assert MachineType.changeset(%MachineType{}, %{name: "X", status: "active"}).valid?
      assert MachineType.changeset(%MachineType{}, %{name: "X", status: "inactive"}).valid?
      refute MachineType.changeset(%MachineType{}, %{name: "X", status: "retired"}).valid?
    end

    test "caps the description length" do
      changeset =
        MachineType.changeset(%MachineType{}, %{
          name: "X",
          description: String.duplicate("d", 1001)
        })

      refute changeset.valid?
      assert %{description: [_]} = errors_on(changeset)
    end

    test "defaults status to active on a new struct" do
      assert %MachineType{status: "active"} = %MachineType{}
    end
  end
end
