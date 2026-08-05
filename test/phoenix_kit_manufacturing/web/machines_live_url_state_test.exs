defmodule PhoenixKitManufacturing.Web.MachinesLiveUrlStateTest do
  # Unit tests — the `use PhoenixKitWeb.Live.UrlState` spec is compiled into
  # `__phoenix_kit_url_state__/0`, so what the LiveView accepts out of the
  # query string can be asserted without a router, a socket, or a DB. The
  # behavioural half (a shared link actually sorting the list) lives in the
  # `:integration`-tagged `MachinesLiveTest`.
  use ExUnit.Case, async: true

  alias PhoenixKitManufacturing.ColumnConfig.Machines, as: MachineColumnConfig
  alias PhoenixKitManufacturing.Web.MachinesLive

  defp spec(key) do
    MachinesLive.__phoenix_kit_url_state__().params
    |> Enum.find(&(&1.key == key))
  end

  test "search is ?q= and defaults to the unfiltered list" do
    assert %{url_key: "q", default: "", cast: :string} = spec(:search)
  end

  # The whitelist is read off the column registry at compile time. Asserting
  # the resolved value (not just "it equals the registry call") is what proves
  # the derivation actually ran — an empty or stale list here would silently
  # reject every ?sort= value and fall back to "name".
  test "?sort= accepts exactly the registry's sortable columns" do
    assert spec(:sort_by).allowed == MachineColumnConfig.sortable_column_ids()

    assert spec(:sort_by).allowed == [
             "name",
             "code",
             "status",
             "location",
             "manufacturer",
             "model",
             "manufacture_year",
             "commissioned_on",
             "warranty_until",
             "to_next_on"
           ]
  end

  # `apply_sort/2` silently no-ops on a column with no `sort_key`, so a
  # `?sort=types` link that got through would render an unsorted list with
  # nothing selected in the sort control.
  test "?sort=types is rejected in favour of the default" do
    refute "types" in spec(:sort_by).allowed
    assert spec(:sort_by).default == "name"
    assert "types" in MachineColumnConfig.all_column_ids()
  end

  # `cast: :atom` without `:in` is a compile-time error in UrlState precisely
  # so no atom is ever created from a URL; pin the pair that satisfies it.
  test "?dir= casts to an atom out of a closed set" do
    assert %{url_key: "dir", default: :asc, cast: :atom, allowed: [:asc, :desc]} = spec(:sort_dir)
  end
end
