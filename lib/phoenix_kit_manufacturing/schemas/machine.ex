defmodule PhoenixKitManufacturing.Schemas.Machine do
  @moduledoc """
  Schema for manufacturing machines (the machines reference book).

  A machine is a piece of production equipment: a CNC mill, a press, a
  laser cutter, etc. Machines are categorized by many-to-many machine
  type links via `MachineTypeAssignment`, so a single machine can carry
  several type tags. `MachineTypeAssignment.machine_type_uuid` is a soft
  reference (no `belongs_to`/FK) — see that schema's moduledoc — so this
  schema does not expose a `machine_types` association; resolving the
  linked types for a machine goes through
  `PhoenixKitManufacturing.Machines`/`EntitiesRegistry` instead.

  The passport columns (`model`, `manufacture_year`, `commissioned_on`,
  `warranty_until`, `to_last_on`, `to_interval_days`, `to_next_on`,
  `notes`) and the soft location link (`location_uuid`, `space_uuid`) are
  first-class columns as of schema V2. `location_uuid`/`space_uuid` are
  intentionally *not* `belongs_to` associations — `phoenix_kit_locations`
  is a soft, optional cross-module reference read via
  `PhoenixKitManufacturing.Machines.location_label/2`, never joined.

  `to_next_on` is auto-computed from `to_last_on` + `to_interval_days`
  whenever both are present and the caller didn't explicitly submit a
  `to_next_on` value of its own — see `maybe_compute_next_maintenance/1`.

  The freeform `metadata` JSONB column holds the remaining passport/spec
  fields driven by each linked machine type's `field_template` (power
  rating, working area, …) that aren't modeled as columns here. `data`
  holds multilang translations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active maintenance repair mothballed decommissioned)

  schema "phoenix_kit_machines" do
    field(:name, :string)
    # Short code / inventory number (e.g. "CNC-01").
    field(:code, :string)
    field(:manufacturer, :string)
    field(:model, :string)
    field(:serial_number, :string)
    field(:description, :string)
    field(:manufacture_year, :integer)

    # Freeform legacy location note, still shown for machines that predate
    # the location_uuid/space_uuid soft link. New records use the link
    # instead (see PhoenixKitManufacturing.Machines.location_label/2).
    field(:location_note, :string)

    # Soft cross-module reference into phoenix_kit_locations — no
    # belongs_to/FK on purpose (that module may not be installed/migrated
    # on every host).
    field(:location_uuid, :binary_id)
    field(:space_uuid, :binary_id)

    # Maintenance schedule: last service date, service interval, and the
    # (auto-computed, unless overridden) next due date.
    field(:commissioned_on, :date)
    field(:warranty_until, :date)
    field(:to_last_on, :date)
    field(:to_interval_days, :integer)
    field(:to_next_on, :date)

    field(:notes, :string)

    field(:status, :string, default: "active")

    # Multilang translations (name/description), managed by MultilangForm.
    field(:data, :map, default: %{})

    # Freeform passport/spec fields not yet promoted to columns.
    field(:metadata, :map, default: %{})

    has_many(:machine_type_assignments, PhoenixKitManufacturing.Schemas.MachineTypeAssignment,
      foreign_key: :machine_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :code,
    :manufacturer,
    :model,
    :serial_number,
    :description,
    :manufacture_year,
    :location_note,
    :location_uuid,
    :space_uuid,
    :commissioned_on,
    :warranty_until,
    :to_last_on,
    :to_interval_days,
    :to_next_on,
    :notes,
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
    |> validate_length(:model, max: 255)
    |> validate_length(:serial_number, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_length(:location_note, max: 500)
    |> validate_length(:notes, max: 2000)
    |> validate_number(:to_interval_days, greater_than: 0)
    |> validate_number(:manufacture_year, greater_than: 1900, less_than: 2101)
    |> validate_inclusion(:status, @statuses)
    |> maybe_compute_next_maintenance()
  end

  @doc "The list of valid status values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  # Keeps `to_next_on` in sync with `to_last_on` + `to_interval_days` when
  # both are present and the caller isn't explicitly overriding
  # `to_next_on` in this very changeset — an explicit `to_next_on` change
  # always wins. Runs last so it sees the final `to_last_on`/
  # `to_interval_days` values from the rest of the pipeline.
  @spec maybe_compute_next_maintenance(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp maybe_compute_next_maintenance(changeset) do
    to_last_on = get_field(changeset, :to_last_on)
    to_interval_days = get_field(changeset, :to_interval_days)
    to_next_on_overridden? = not is_nil(get_change(changeset, :to_next_on))

    if to_last_on && to_interval_days && not to_next_on_overridden? do
      put_change(changeset, :to_next_on, Date.add(to_last_on, to_interval_days))
    else
      changeset
    end
  end
end
