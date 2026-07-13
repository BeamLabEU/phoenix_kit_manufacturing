defmodule PhoenixKitManufacturing.Schemas.MachineType do
  @moduledoc "Schema for machine types (e.g., CNC, Milling, Press, Laser cutter)."

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive)

  schema "phoenix_kit_machine_types" do
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "active")

    # Multilang translations (name/description), managed by MultilangForm.
    field(:data, :map, default: %{})

    has_many(:machine_type_assignments, PhoenixKitManufacturing.Schemas.MachineTypeAssignment,
      foreign_key: :machine_type_uuid,
      references: :uuid
    )

    has_many(:machines, through: [:machine_type_assignments, :machine])

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:description, :status, :data]

  @doc "Builds a changeset for a machine type."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(machine_type, attrs) do
    machine_type
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 1000)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "The list of valid status values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
