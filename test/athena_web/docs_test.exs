defmodule AthenaWeb.DocsTest do
  use ExUnit.Case, async: true

  alias AthenaWeb.Docs
  alias AthenaWeb.Docs.Converter

  @sources Path.wildcard("priv/docs/**/*.md")

  test "both languages have exactly the same pages" do
    paths = fn lang ->
      for page <- Docs.all(), page.lang == lang, into: MapSet.new(), do: page.path
    end

    missing_en = MapSet.difference(paths.("ru"), paths.("en")) |> Enum.sort()
    missing_ru = MapSet.difference(paths.("en"), paths.("ru")) |> Enum.sort()

    assert missing_en == [], "pages without an English version: #{inspect(missing_en)}"
    assert missing_ru == [], "pages without a Russian version: #{inspect(missing_ru)}"
  end

  test "the table of contents has sections with pages, in order" do
    for lang <- Docs.languages() do
      tree = Docs.tree(lang)
      assert tree != []
      assert Enum.all?(tree, &(&1.section.kind == :section))
      orders = Enum.map(tree, & &1.section.section_order)
      assert orders == Enum.sort(orders)
    end
  end

  describe "writing rules" do
    test "no em dash anywhere - use an en dash" do
      offenders = for path <- @sources, File.read!(path) =~ "—", do: path
      assert offenders == [], "em dash found in: #{inspect(offenders)}"
    end

    test "the interface itself has no em dash either, so quoted labels match the rule" do
      sources =
        Path.wildcard("priv/gettext/**/*.{po,pot}") ++
          Path.wildcard("lib/**/*.{ex,heex}") ++ Path.wildcard("assets/js/**/*.js")

      offenders = for path <- sources, File.read!(path) =~ "—", do: path
      assert offenders == [], "em dash found in: #{inspect(offenders)}"
    end

    test "the Russian version says учебная группа / команда and обучающийся / пользователь" do
      offenders =
        for path <- @sources,
            String.contains?(path, "/ru/"),
            File.read!(path) =~ ~r/когорт|студент/iu,
            do: path

      assert offenders == [], "forbidden wording in: #{inspect(offenders)}"
    end

    test "exports are not documented" do
      offenders =
        for path <- @sources, File.read!(path) =~ ~r/\bCSV\b|экспорт|\bexport/iu, do: path

      assert offenders == [], "export mentioned in: #{inspect(offenders)}"
    end
  end

  describe "interface labels" do
    test ":ui[...] becomes the label exactly as the interface shows it in that language" do
      assert Converter.resolve_ui_labels("Open :ui[Group Radar].", "ru") ==
               ~s(Open <span class="ui-label">Радар группы</span>.)

      assert Converter.resolve_ui_labels(":ui[Group Radar]", "en") =~ "Group Radar"
    end

    test "a label the interface doesn't have fails the build" do
      assert_raise ArgumentError, ~r/unknown interface label :ui\[Launch rockets\]/, fn ->
        Converter.resolve_ui_labels(":ui[Launch rockets]", "ru", "priv/docs/ru/x.md")
      end
    end
  end

  test "get/2 finds pages and sections, nothing else" do
    [%{section: section, pages: [page | _]} | _] = Docs.tree("ru")

    assert {:ok, %{kind: :section}, false} = Docs.get("ru", section.path)
    assert {:ok, ^page, false} = Docs.get("ru", page.path)
    assert Docs.get("ru", "no/such-page") == :error
  end
end
