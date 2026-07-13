defmodule PhoenixKitManufacturing.Schemas.MachineTypeAssignment do
  @moduledoc "Join table for the many-to-many between machines and machine types."

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_machine_type_assignments" do
    belongs_to(:machine, PhoenixKitManufacturing.Schemas.Machine,
      foreign_key: :machine_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:machine_type, PhoenixKitManufacturing.Schemas.MachineType,
      foreign_key: :machine_type_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds an insert changeset for a machine ↔ type assignment.

  Casts the two FK columns + timestamps and wires `assoc_constraint/2` on
  both associations so an FK violation comes back as a clean
  `{:error, changeset}` instead of raising `Ecto.ConstraintError`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:machine_uuid, :machine_type_uuid, :inserted_at, :updated_at])
    |> validate_required([:machine_uuid, :machine_type_uuid])
    |> assoc_constraint(:machine)
    |> assoc_constraint(:machine_type)
  end
end
