defmodule PhoenixKitManufacturing.Schemas.MachineTest do
  use ExUnit.Case, async: true

  alias PhoenixKitManufacturing.Schemas.Machine

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "is valid with just a name" do
      changeset = Machine.changeset(%Machine{}, %{name: "CNC-01"})
      assert changeset.valid?
    end

    test "casts the full set of optional fields" do
      attrs = %{
        name: "CNC-01",
        code: "M-001",
        manufacturer: "Haas",
        serial_number: "SN-123",
        description: "3-axis mill",
        location_note: "Shop floor A",
        status: "maintenance",
        metadata: %{"power_kw" => 7.5}
      }

      changeset = Machine.changeset(%Machine{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == "maintenance"
      assert Ecto.Changeset.get_change(changeset, :metadata) == %{"power_kw" => 7.5}
    end

    test "requires a name" do
      changeset = Machine.changeset(%Machine{}, %{})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an unknown status" do
      changeset = Machine.changeset(%Machine{}, %{name: "X", status: "on_fire"})
      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts each documented status" do
      for status <- Machine.statuses() do
        changeset = Machine.changeset(%Machine{}, %{name: "X", status: status})
        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "enforces the name length ceiling" do
      changeset = Machine.changeset(%Machine{}, %{name: String.duplicate("a", 256)})
      refute changeset.valid?
      assert %{name: [_]} = errors_on(changeset)
    end

    test "defaults status to active on a new struct" do
      assert %Machine{status: "active"} = %Machine{}
    end
  end
end
