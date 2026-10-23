defmodule PhoenixKitManufacturing.GettextCatalogParityTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the shipped gettext catalogs against drifting apart: every locale's
  `default.po` must carry exactly the messages of `default.pot`. A msgid added to
  only some locales (as happened with the "Machine Type Template" sidebar tab,
  translated in et/ru but missing from the template and en) means the next
  `mix gettext.extract --merge` silently rewrites the catalogs, and the
  template stops being a trustworthy list of translatable strings.
  """

  @pot "priv/gettext/default.pot"
  @locales Path.wildcard("priv/gettext/*/LC_MESSAGES/default.po")

  test "at least the en/et/ru catalogs are covered" do
    locales = Enum.map(@locales, &(&1 |> Path.dirname() |> Path.dirname() |> Path.basename()))
    assert ["en", "et", "ru"] -- locales == []
  end

  for po <- @locales do
    locale = po |> Path.dirname() |> Path.dirname() |> Path.basename()

    test "#{locale} default.po has the same msgids as default.pot" do
      template = @pot |> File.read!() |> message_keys()
      locale_ids = unquote(po) |> File.read!() |> message_keys()

      assert MapSet.to_list(MapSet.difference(template, locale_ids)) == [],
             "#{unquote(locale)} is missing messages: " <>
               inspect(MapSet.difference(template, locale_ids))

      assert MapSet.to_list(MapSet.difference(locale_ids, template)) == [],
             "#{unquote(locale)} has unexpected messages: " <>
               inspect(MapSet.difference(locale_ids, template))
    end
  end

  test "message identity includes multiline IDs, contexts and plural IDs" do
    catalog = ~S'''
    msgid ""
    "Long "
    "message"
    msgstr ""

    msgctxt "machine"
    msgid "Open"
    msgstr ""

    msgid "One machine"
    msgid_plural "Many machines"
    msgstr[0] ""
    msgstr[1] ""
    '''

    assert message_keys(catalog) ==
             MapSet.new([
               {{"", "Long message"}, nil},
               {{"machine", "Open"}, nil},
               {{"", "One machine"}, "Many machines"}
             ])
  end

  test "obsolete translations do not count as active messages" do
    assert message_keys(~S'''
           #~ msgid "Retired"
           #~ msgstr "Retired"
           ''') == MapSet.new()
  end

  test "runtime tab and permission labels are present in the template" do
    template = @pot |> File.read!() |> message_keys()
    metadata = PhoenixKitManufacturing.permission_metadata()

    labels = [metadata.label | Enum.map(PhoenixKitManufacturing.admin_tabs(), & &1.label)]

    for label <- labels do
      assert MapSet.member?(template, {{"", label}, nil}),
             "runtime label #{inspect(label)} is missing from default.pot"
    end
  end

  defp message_keys(contents) do
    contents
    |> Expo.PO.parse_string!()
    |> Map.fetch!(:messages)
    |> Enum.reject(& &1.obsolete)
    |> MapSet.new(fn message ->
      plural =
        case message do
          %Expo.Message.Plural{msgid_plural: plural} -> IO.iodata_to_binary(plural)
          %Expo.Message.Singular{} -> nil
        end

      {Expo.Message.key(message), plural}
    end)
  end
end
