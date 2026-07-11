defmodule PhoenixKitManufacturing.Schemas.Machine do
  @moduledoc """
  Schema for manufacturing machines (the machines reference book).

  A machine is a piece of production equipment: a CNC mill, a press, a
  laser cutter, etc. Machines are categorized by many-to-many
  `MachineType` links, so a single machine can carry several type tags.

  The freeform `metadata` JSONB column holds passport/spec fields that are
  not yet modeled as columns (power rating, working area, commissioning
  date, maintenance schedule…), so early iterations don't need a migration
  for every new attribute. `data` holds multilang translations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active maintenance decommissioned)

  schema "phoenix_kit_machines" do
    field(:name, :string)
    # Short code / inventory number (e.g. "CNC-01").
    field(:code, :string)
    field(:manufacturer, :string)
    field(:serial_number, :string)
    field(:description, :string)

    # Freeform location note. A future revision may link this to
    # phoenix_kit_locations by UUID; kept as text to avoid a hard
    # cross-module dependency for now.
    field(:location_note, :string)

    field(:status, :string, default: "active")

    # Multilang translations (name/description), managed by MultilangForm.
    field(:data, :map, default: %{})

    # Freeform passport/spec fields not yet promoted to columns.
    field(:metadata, :map, default: %{})

    has_many(:machine_type_assignments, PhoenixKitManufacturing.Schemas.MachineTypeAssignment,
      foreign_key: :machine_uuid,
      references: :uuid
    )

    has_many(:machine_types, through: [:machine_type_assignments, :machine_type])

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :code,
    :manufacturer,
    :serial_number,
    :description,
    :location_note,
    :status,
    :data,
    :metadata
  ]

  @doc "Builds a changeset for a machine."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(machine, attrs) do
    machine
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:code, max: 100)
    |> validate_length(:manufacturer, max: 255)
    |> validate_length(:serial_number, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_length(:location_note, max: 500)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "The list of valid status values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
