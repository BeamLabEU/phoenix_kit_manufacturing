defmodule PhoenixKitManufacturing.ColumnConfig.Machines do
  @moduledoc """
  Column registry for the Machines index list LiveView
  (`PhoenixKitManufacturing.Web.MachinesLive`, `:index`).

  Operates on enriched machine maps of shape `%{uuid, name, code, status,
  status_label, location, types_csv, type_names, manufacturer, model,
  manufacture_year, commissioned_on, warranty_until, to_next_on, data}`,
  built by `enrich_machines/2` in the LiveView the same way
  `PhoenixKitWarehouse.ColumnConfig.Inventories`'s flat maps are built by
  `enrich_documents/1` in `inventories_live.ex`.

  `types_csv` is the sorted, comma-joined list of machine type names (e.g.
  `"CNC, Milling"`) used as the `:enum` filter key — `distinct_options/2`
  returns distinct CSV strings and `enum_filter/1` matches on the full CSV.
  `type_names` (a sorted list of the same strings) is kept on the enriched
  map for badge rendering in the LiveView without re-splitting the CSV.
  """

  use PhoenixKitManufacturing.ColumnConfig, scope: "manufacturing_machines"

  alias PhoenixKitManufacturing.Schemas.Machine

  # Split into three groups purely to keep each function under credo's
  # cyclomatic-complexity ceiling — the anonymous fns in each column
  # definition each count as a branch. Order is preserved: identity,
  # then placement/model, then dates.
  defp columns, do: identity_columns() ++ placement_columns() ++ date_columns()

  defp identity_columns do
    [
      %{
        id: "name",
        label: fn -> gettext("Name") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &String.downcase(&1.name || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.name || ""))
      },
      %{
        id: "code",
        label: fn -> gettext("Code") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &String.downcase(&1.code || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.code || ""))
      },
      %{
        id: "status",
        label: fn -> gettext("Status") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &(&1.status || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :enum,
        filter_options: fn _entries -> Enum.map(Machine.statuses(), &{&1, status_label(&1)}) end,
        filter_apply: enum_filter(&(&1.status || ""))
      }
    ]
  end

  defp placement_columns do
    [
      %{
        id: "location",
        label: fn -> gettext("Location") end,
        default?: true,
        align: :left,
        sortable?: true,
        sort_key: &String.downcase(&1.location || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.location || ""))
      },
      %{
        id: "types",
        label: fn -> gettext("Types") end,
        default?: true,
        align: :left,
        sortable?: false,
        filterable?: true,
        filter_type: :enum,
        filter_options: fn entries -> distinct_options(entries, :types_csv) end,
        filter_apply: enum_filter(&(&1.types_csv || ""))
      },
      %{
        id: "manufacturer",
        label: fn -> gettext("Manufacturer") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &String.downcase(&1.manufacturer || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.manufacturer || ""))
      },
      %{
        id: "model",
        label: fn -> gettext("Model") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &String.downcase(&1.model || ""),
        default_dir: :asc,
        filterable?: true,
        filter_type: :text,
        filter_apply: text_filter(&(&1.model || ""))
      }
    ]
  end

  defp date_columns do
    [
      %{
        id: "manufacture_year",
        label: fn -> gettext("Manufacture year") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &(&1.manufacture_year || 0),
        default_dir: :desc,
        filterable?: true,
        filter_type: :numeric_range,
        filter_apply: numeric_range_filter(&(&1.manufacture_year || 0))
      },
      %{
        id: "commissioned_on",
        label: fn -> gettext("Commissioned on") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &date_sort_key(&1.commissioned_on),
        default_dir: :desc,
        filterable?: true,
        filter_type: :date_range,
        filter_apply: date_range_filter(&date_of(&1.commissioned_on))
      },
      %{
        id: "warranty_until",
        label: fn -> gettext("Warranty until") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &date_sort_key(&1.warranty_until),
        default_dir: :desc,
        filterable?: true,
        filter_type: :date_range,
        filter_apply: date_range_filter(&date_of(&1.warranty_until))
      },
      %{
        id: "to_next_on",
        label: fn -> gettext("Next maintenance due") end,
        default?: false,
        align: :left,
        sortable?: true,
        sort_key: &date_sort_key(&1.to_next_on),
        default_dir: :asc,
        filterable?: true,
        filter_type: :date_range,
        filter_apply: date_range_filter(&date_of(&1.to_next_on))
      }
    ]
  end

  # Mirrors Web.MachinesLive's private status_label/1 (same clauses, same
  # gettext msgids — reuses the existing translations rather than minting
  # near-duplicate ones). Duplicated rather than shared: this module can't
  # depend on the LiveView, and every PhoenixKitWarehouse.ColumnConfig.*
  # file hardcodes its own enum filter_options labels the same way (see
  # e.g. `inventories.ex`'s draft/posted status_label pairs) rather than
  # reaching into a LiveView for a handful of label clauses.
  defp status_label("active"), do: gettext("Active")
  defp status_label("maintenance"), do: gettext("Maintenance")
  defp status_label("repair"), do: gettext("Repair")
  defp status_label("mothballed"), do: gettext("Mothballed")
  defp status_label("decommissioned"), do: gettext("Decommissioned")
  defp status_label(other), do: other

  # Chronological sort key for a nullable passport `Date.t()` column.
  # ISO-8601 strings sort lexically identically to chronological order
  # (unlike the raw `%Date{}` struct, whose field order is alphabetical —
  # comparing structs directly with `<=` would sort by day before year).
  # `nil` (no date set) sorts first ascending, same "missing data compares
  # as the identity element" convention as the engine's own
  # `datetime_to_unix(nil) -> 0`.
  defp date_sort_key(nil), do: ""
  defp date_sort_key(%Date{} = date), do: Date.to_iso8601(date)
end
