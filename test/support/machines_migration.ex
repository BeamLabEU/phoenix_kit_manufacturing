defmodule PhoenixKitManufacturing.Test.MachinesMigration do
  @moduledoc """
  Static `Ecto.Migration` wrapper so the module's own
  `PhoenixKitManufacturing.Migrations.Machines` migration can be applied in
  tests via `Ecto.Migrator.up/4`.

  `Ecto.Migration.execute/1` (used inside `Migrations.Machines.up/1`) needs
  a live migration-runner process, which `Ecto.Migrator.up/4` sets up. This
  mirrors exactly how the real host applies the module's tables through the
  wrapper migration that `mix phoenix_kit.update` generates. Tests always run
  against the `"public"` schema.
  """

  use Ecto.Migration

  alias PhoenixKitManufacturing.Migrations.Machines

  def up, do: Machines.up(prefix: "public")
  def down, do: Machines.down(prefix: "public")
end
