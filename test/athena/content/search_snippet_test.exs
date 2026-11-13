defmodule Athena.Content.SearchSnippetTest do
  use ExUnit.Case, async: true
  alias Athena.Content.SearchSnippet

  test "HTML remains plain text in safe segments" do
    result =
      SearchSnippet.build(
        "<img src=x onerror=alert(1)> needle <script>bad()</script>",
        "needle",
        true
      )

    assert result.snippet == [
             %{text: "<img src=x onerror=alert(1)> ", match?: false},
             %{text: "needle", match?: true},
             %{text: " <script>bad()</script>", match?: false}
           ]

    assert Enum.all?(result.snippet, &is_binary(&1.text))
  end

  test "all literal occurrences preserve case and Unicode" do
    result = SearchSnippet.build("Ёжик и ёжик", "ёжик", true)
    assert Enum.filter(result.snippet, & &1.match?) |> Enum.map(& &1.text) == ["Ёжик", "ёжик"]
  end

  test "a maximum length phrase fits near the end of a long block" do
    query = String.duplicate("я", 200)
    result = SearchSnippet.build(String.duplicate("Начало ", 100) <> query, query, true)
    assert Enum.any?(result.snippet, &(&1.match? and &1.text == query))
    assert String.length(Enum.map_join(result.snippet, & &1.text)) <= 240
    assert String.length(result.title) <= 80
  end

  test "the title comes from the first nonempty line" do
    assert SearchSnippet.build("\n   \nЗаголовок\nТело needle", "needle", true).title ==
             "Заголовок"
  end

  test "fuzzy multiword context can be selected near the end" do
    text = String.duplicate("Вступительное слово. ", 100) <> "Бинарный поиск в массиве"
    result = SearchSnippet.build(text, "бинарный поик", false)
    assert Enum.map_join(result.snippet, & &1.text) =~ "Бинарный поиск"
    refute Enum.any?(result.snippet, & &1.match?)
  end
end
