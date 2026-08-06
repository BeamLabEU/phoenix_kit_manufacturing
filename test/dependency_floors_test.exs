defmodule PhoenixKitManufacturing.DependencyFloorsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the published dependency contract in `mix.exs`. This module `use`s
  and calls sibling-package APIs that arrived mid-`0.x`/mid-`1.7.x`; a
  requirement whose floor predates one of them still *resolves* — the
  workspace never notices, because it pins the latest of everything — but a
  consumer whose resolution lands lower gets a package referencing a module
  or function that isn't there.

  Each case names the last release **without** the API and the first release
  **with** it, so a floor that drifts back below an API this module depends
  on fails here instead of in someone else's build.
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

  defp assert_floor(app, last_without, first_with) do
    case requirement(app) do
      nil ->
        # Local checkout via <APP>_PATH — nothing to assert.
        :ok

      req ->
        refute Version.match?(last_without, req),
               "#{app} #{req} still permits #{last_without}, which predates an API this module uses"

        assert Version.match?(first_with, req),
               "#{app} #{req} excludes #{first_with}, the release that first shipped the API this module uses"
    end
  end

  test "phoenix_kit's floor covers PhoenixKitWeb.Live.UrlState (1.7.231)" do
    assert_floor(:phoenix_kit, "1.7.230", "1.7.231")
  end

  test "phoenix_kit_comments' floor covers subscribe/2 and batch count_comments/3 (0.2.8)" do
    assert_floor(:phoenix_kit_comments, "0.2.7", "0.2.8")
  end

  test "phoenix_kit_locations' floor covers PlacePicker and Spaces.full_path (0.3.0)" do
    assert_floor(:phoenix_kit_locations, "0.2.1", "0.3.0")
  end

  test "phoenix_kit_entities' floor covers the EntityData/Events API (0.2.7)" do
    assert Version.match?("0.2.7", requirement(:phoenix_kit_entities) || "~> 0.2.7")
  end
end
