defmodule PhoenixKitManufacturing.GettextCatalogParityTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the shipped gettext catalogs against drifting apart: every locale's
  `default.po` must carry exactly the msgids of `default.pot`. A msgid added to
  only some locales (as happened with the "Machine Type Template" sidebar tab,
  translated in et/ru but missing from the template and en) means the next
  `mix gettext.extract --merge` silently rewrites the catalogs, and the
  template stops being a trustworthy list of translatable strings.
  """

  @pot "priv/gettext/default.pot"
  @locales Path.wildcard("priv/gettext/*/LC_MESSAGES/default.po")

  test "at least the en/et/ru catalogs are covered" do
    locales = Enum.map(@locales, &(&1 |> Path.dirname() |> Path.dirname() |> Path.basename()))
    assert Enum.sort(locales) == ["en", "et", "ru"]
  end

  for po <- @locales do
    locale = po |> Path.dirname() |> Path.dirname() |> Path.basename()

    test "#{locale} default.po has the same msgids as default.pot" do
      template = msgids(@pot)
      locale_ids = msgids(unquote(po))

      assert MapSet.to_list(MapSet.difference(template, locale_ids)) == [],
             "#{unquote(locale)} is missing msgids present in default.pot"

      assert MapSet.to_list(MapSet.difference(locale_ids, template)) == [],
             "#{unquote(locale)} has msgids absent from default.pot " <>
               "(run `mix gettext.extract --merge`)"
    end
  end

  # Single-line msgids only; multi-line ones start with `msgid ""` and are
  # skipped identically on both sides, so the comparison stays symmetric.
  defp msgids(path) do
    ~r/^msgid "(.+)"$/m
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> MapSet.new(fn [id] -> id end)
  end
end
