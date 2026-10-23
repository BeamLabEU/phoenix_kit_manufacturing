defmodule PhoenixKitManufacturing.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a single
  core MINOR, and against a local path override reaching a commit.

  The trap is the three-segment form: `~> 2.0.x` expands to
  `>= 2.0.x and < 2.1.0`, so no 2.1 or later core satisfies it. The breakage
  lands on CONSUMERS, never here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set and `mix deps.get` fails
  outright, with no degraded mode. Nothing else in this repo's own test run
  would notice, which is why the check is a test rather than a convention.

  Core 1.7 is deliberately excluded: core 2.0.0 squashed the migration chain to
  a V135 floor and this module is verified only against that baseline.
  """

  @must_admit ["2.0.0", "2.0.7", "2.1.0", "2.9.4"]
  @must_reject ["1.7.189", "1.7.236", "1.9.4", "3.0.0"]

  test "the :phoenix_kit requirement admits every core 2.x and nothing else" do
    assert {:ok, requirement} = published_requirement(File.read!("mix.exs"), :phoenix_kit)

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor breaks `mix deps.get` for every host " <>
               "running this module alongside that core. Keep it a two-segment `~> 2.0`."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "which is outside the range this module is verified against."
    end
  end

  test "all PhoenixKit dependencies retain a published Hex requirement" do
    source = File.read!("mix.exs")

    for app <- [
          :phoenix_kit,
          :phoenix_kit_comments,
          :phoenix_kit_entities,
          :phoenix_kit_locations
        ] do
      assert {:ok, requirement} = published_requirement(source, app),
             "#{app} must use a Hex requirement; use its <APP>_PATH variable for local work"

      assert {:ok, _} = Version.parse_requirement(requirement)
    end
  end

  test "committed path and git dependencies fail even with a version or a commented Hex pin" do
    for dependency <- [
          ~s({:phoenix_kit, path: "../phoenix_kit"}),
          ~s({:phoenix_kit, "~> 2.0", path: "../phoenix_kit"}),
          ~s({:phoenix_kit, "~> 2.0", git: "https://example.com/core.git"}),
          ~s|pk_dep(:phoenix_kit, "~> 2.0", path: "../phoenix_kit")|
        ] do
      source = """
      # pk_dep(:phoenix_kit, "~> 2.0")
      defp deps, do: [#{dependency}]
      """

      assert published_requirement(source, :phoenix_kit) == :error
    end
  end

  test "published pins work in both tuple forms and through the local-override helper" do
    for dependency <- [
          ~s({:phoenix_kit, "~> 2.0"}),
          ~s({:phoenix_kit, "~> 2.0", runtime: false}),
          ~s|pk_dep(:phoenix_kit, "~> 2.0")|
        ] do
      source = "defp deps, do: [#{dependency}]"
      assert published_requirement(source, :phoenix_kit) == {:ok, "~> 2.0"}
    end
  end

  # Read the declared dependencies, not this run's env-rewritten resolution.
  # Parsing ignores commented pins and catches non-Hex options even when a
  # version string accompanies them. No environment changes are needed.
  defp published_requirement(source, app) do
    {_, [dependencies]} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defp, _, [{:deps, _, args}, [do: dependencies]]} = node, acc
        when args in [nil, []] ->
          {node, [dependencies | acc]}

        node, acc ->
          {node, acc}
      end)

    dependencies
    |> Enum.map(&dependency_parts/1)
    |> Enum.find(&match?({^app, _, _}, &1))
    |> case do
      {^app, requirement, opts} when is_binary(requirement) and is_list(opts) ->
        if Enum.any?([:path, :git, :github, :in_umbrella], &Keyword.has_key?(opts, &1)),
          do: :error,
          else: {:ok, requirement}

      _ ->
        :error
    end
  end

  defp dependency_parts({:pk_dep, _, [app, requirement]}), do: {app, requirement, []}
  defp dependency_parts({:pk_dep, _, [app, requirement, opts]}), do: {app, requirement, opts}
  defp dependency_parts({:{}, _, [app, requirement, opts]}), do: {app, requirement, opts}
  defp dependency_parts({app, requirement}), do: {app, requirement, []}
  defp dependency_parts(_), do: nil
end
