defmodule PhoenixKitManufacturing.Schemas.MachineTypeAssignment do
  @moduledoc """
  Join table for the many-to-many between machines and machine types.

  `machine_type_uuid` is a **soft reference** into `phoenix_kit_entities`
  (`EntityData.uuid` for the `machine_type` entity), not an
  `Ecto.Schema.belongs_to/3` association — `machine_type` data lives in a
  separate package with no FK to point at (see
  `PhoenixKitManufacturing.EntitiesRegistry`). `machine` stays a normal
  association since `Machine` remains a schema of this module.
  """

  use Ecto.Schema
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

    field(:machine_type_uuid, UUIDv7)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds an insert changeset for a machine ↔ type assignment.

  Casts the two FK columns + timestamps and wires `assoc_constraint/2` on
  the `machine` association so an FK violation comes back as a clean
  `{:error, changeset}` instead of raising `Ecto.ConstraintError`.
  `machine_type_uuid` is a soft reference (see moduledoc) — there is no
  Postgres FK left to violate, so no `assoc_constraint/2` for it.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:machine_uuid, :machine_type_uuid, :inserted_at, :updated_at])
    |> validate_required([:machine_uuid, :machine_type_uuid])
    |> assoc_constraint(:machine)
  end
end
