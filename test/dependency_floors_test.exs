defmodule PhoenixKitManufacturing.DependencyFloorsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the published dependency contract in `mix.exs`. This module `use`s
  and calls sibling-package APIs that arrived mid-`0.x`/mid-`1.7.x`; a
  requirement whose floor predates one of them still *resolves* — the
  workspace never notices, because it pins the latest of everything — but a
  consumer whose resolution lands lower gets a package referencing a module
  or function that isn't there.

  Each case names the last release **without** the API, so a floor that
  drifts back below an API this module depends on fails here instead of in
  someone else's build.

  ## Why the "first release with the API" half is gone

  These cases used to assert the requirement *admitted* the release that
  first shipped each API. That held while every pin sat just above its
  marker. It stopped holding in the phoenix_kit 2.0 sweep (2026-08-10),
  which moved every pin far above: core to `~> 2.0`, and the siblings to
  the first minors requiring it. Those markers are now history — kept
  because they record **which API each dependency rests on**, which is what
  a future floor change needs to know — but asserting they still resolve
  would assert the pins had *not* moved up, the opposite of the intent.

  What remains is the half that still catches a real mistake: a pin drifting
  back **down** past an API this module calls.
  """

  # `pk_dep/3` swaps the Hex requirement for a `path:` tuple when the
  # matching `<APP>_PATH` env var is set (see mix.exs) — there is no
  # requirement string to check in a local cross-repo run.
  defp requirement(app) do
    Enum.find_value(Mix.Project.config()[:deps], fn
      {^app, req} when is_binary(req) -> req
      {^app, req, _opts} when is_binary(req) -> req
      _ -> nil
    end)
  end

  defp refute_floor_below(app, last_without) do
    case requirement(app) do
      nil ->
        # Local checkout via <APP>_PATH — nothing to assert.
        :ok

      req ->
        refute Version.match?(last_without, req),
               "#{app} #{req} still permits #{last_without}, which predates an API this module uses"
    end
  end

  test "phoenix_kit's floor stays above the release before PhoenixKitWeb.Live.UrlState (1.7.231)" do
    refute_floor_below(:phoenix_kit, "1.7.230")
  end

  test "phoenix_kit_comments' floor stays above the release before subscribe/2 and batch count_comments/3 (0.2.8)" do
    refute_floor_below(:phoenix_kit_comments, "0.2.7")
  end

  test "phoenix_kit_locations' floor stays above the release before PlacePicker and Spaces.full_path (0.3.0)" do
    refute_floor_below(:phoenix_kit_locations, "0.2.1")
  end

  test "phoenix_kit_entities' floor stays above the release before the EntityData/Events API (0.2.7)" do
    refute_floor_below(:phoenix_kit_entities, "0.2.6")
  end

  test "every sibling pin requires a core-2.0-era release" do
    # The sweep's actual contract: this module and every sibling it depends on
    # must resolve to a release built against core 2.x. A pin that slipped back
    # to a 1.7-era sibling would resolve, then fail at `mix deps.get` in the
    # consumer's build with an unsatisfiable core requirement.
    for {app, first_core_2_release} <- [
          {:phoenix_kit, "2.0.0"},
          {:phoenix_kit_comments, "0.3.0"},
          {:phoenix_kit_entities, "0.3.0"},
          {:phoenix_kit_locations, "0.4.0"}
        ] do
      case requirement(app) do
        nil ->
          :ok

        req ->
          assert Version.match?(first_core_2_release, req),
                 "#{app} #{req} excludes #{first_core_2_release}, its first release requiring core 2.0"
      end
    end
  end
end
