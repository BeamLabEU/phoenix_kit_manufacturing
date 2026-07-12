defmodule PhoenixKitManufacturing.ViewConfigs do
  @moduledoc """
  Minimal per-user, per-scope view-preference store for Manufacturing's
  admin list pages — currently the Machines index's saved columns and
  active filters (see `PhoenixKitManufacturing.ColumnConfig` /
  `Web.ColumnManagement`).

  Core owns the module's tables now (see
  `PhoenixKit.Migrations.Postgres.V143`); a standalone preferences table
  would need its own core PR. Instead this module stores a
  `%{"columns" => [...], "active_filters" =>
  [...]}`-shaped map as a JSON-encoded blob in `phoenix_kit_settings`
  (core's flat key-value table), one row per `(scope, user_uuid)` pair,
  keyed `"manufacturing_view_config:<scope>:<user_uuid>"`.

  This is a 1:1 adaptation of `PhoenixKitWarehouse.ViewConfigs` — same
  trade-off applies: `phoenix_kit_settings` has no secondary index on "all
  rows for this user", which is fine at this module's scale (currently one
  scope — `manufacturing_machines` — times however many users actually
  customize columns) but is not a pattern to reach for at higher fan-out.
  """

  alias PhoenixKit.Settings

  @doc "Returns the user's saved view config for `scope`, or `%{}` if none exists yet."
  @spec get_view_config(binary(), String.t()) :: map()
  def get_view_config(user_uuid, scope) when is_binary(user_uuid) and is_binary(scope) do
    case Settings.get_setting(setting_key(user_uuid, scope), nil) do
      nil ->
        %{}

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end
    end
  end

  @doc """
  Merges `partial` into the user's existing view config for `scope` and
  persists the result. Keys absent from `partial` are preserved.
  """
  @spec merge_view_config(binary(), String.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def merge_view_config(user_uuid, scope, partial)
      when is_binary(user_uuid) and is_binary(scope) and is_map(partial) do
    merged = Map.merge(get_view_config(user_uuid, scope), partial)

    case Settings.update_setting(setting_key(user_uuid, scope), Jason.encode!(merged)) do
      {:ok, _setting} -> {:ok, merged}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp setting_key(user_uuid, scope), do: "manufacturing_view_config:#{scope}:#{user_uuid}"
end
