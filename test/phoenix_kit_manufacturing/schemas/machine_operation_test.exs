defmodule PhoenixKitManufacturing.Schemas.MachineOperationTest do
  use ExUnit.Case, async: true

  alias PhoenixKitManufacturing.Schemas.MachineOperation

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  describe "changeset/2" do
    test "is valid with machine_uuid, operation_uuid, and no override" do
      changeset =
        MachineOperation.changeset(%MachineOperation{}, %{
          machine_uuid: Ecto.UUID.generate(),
          operation_uuid: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :time_norm_seconds) == nil
    end

    test "requires machine_uuid" do
      changeset =
        MachineOperation.changeset(%MachineOperation{}, %{operation_uuid: Ecto.UUID.generate()})

      refute changeset.valid?
      assert %{machine_uuid: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires operation_uuid" do
      changeset =
        MachineOperation.changeset(%MachineOperation{}, %{machine_uuid: Ecto.UUID.generate()})

      refute changeset.valid?
      assert %{operation_uuid: ["can't be blank"]} = errors_on(changeset)
    end

    test "casts a time_norm_seconds override" do
      changeset =
        MachineOperation.changeset(%MachineOperation{}, %{
          machine_uuid: Ecto.UUID.generate(),
          operation_uuid: Ecto.UUID.generate(),
          time_norm_seconds: 90
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :time_norm_seconds) == 90
    end

    test "rejects a negative time_norm_seconds override" do
      changeset =
        MachineOperation.changeset(%MachineOperation{}, %{
          machine_uuid: Ecto.UUID.generate(),
          operation_uuid: Ecto.UUID.generate(),
          time_norm_seconds: -1
        })

      refute changeset.valid?
      assert %{time_norm_seconds: [_]} = errors_on(changeset)
    end

    test "accepts a zero time_norm_seconds override" do
      changeset =
        MachineOperation.changeset(%MachineOperation{}, %{
          machine_uuid: Ecto.UUID.generate(),
          operation_uuid: Ecto.UUID.generate(),
          time_norm_seconds: 0
        })

      assert changeset.valid?
    end

    test "wires assoc_constraint on the machine association only" do
      changeset =
        MachineOperation.changeset(%MachineOperation{}, %{
          machine_uuid: Ecto.UUID.generate(),
          operation_uuid: Ecto.UUID.generate()
        })

      constraint_fields = Enum.map(changeset.constraints, & &1.field)
      assert :machine in constraint_fields
      # operation_uuid is a soft reference (phoenix_kit_entities), not an
      # Ecto association — no assoc_constraint/2, no FK to violate.
      refute :operation in constraint_fields
    end
  end
end
