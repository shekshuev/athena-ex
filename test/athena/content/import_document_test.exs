defmodule Athena.Content.ImportDocumentTest do
  use ExUnit.Case, async: true
  alias Athena.Content.{ImportDocument, QuestionImport}

  test "HTML becomes structured rich text with safe marks, entities, code and external images" do
    doc =
      ImportDocument.from(
        "<p>Hello <strong>world</strong> &amp; &nbsp; &lt;tag&gt;<br>Next</p><pre><code>a &lt; b\n{}</code></pre><img src='https://example.org/a.png' alt='Photo' onerror='bad()'>",
        "html"
      )

    assert [
             %{"type" => "paragraph", "content" => inline},
             %{"type" => "codeBlock"},
             %{"type" => "image", "attrs" => attrs}
           ] = doc["content"]

    assert Enum.any?(inline, &(&1["marks"] == [%{"type" => "bold"}]))
    assert ImportDocument.plain(doc) =~ "world & \u00A0 <tag>"
    assert attrs == %{"src" => "https://example.org/a.png", "alt" => "Photo"}
  end

  test "plain text remains literal and markdown produces formatting" do
    doc = ImportDocument.from("<b>literal</b>\nnext", "plain")
    assert ImportDocument.plain(doc) == "<b>literal</b>\nnext"

    assert ImportDocument.from("**bold**", "markdown")["content"]
           |> hd()
           |> Map.fetch!("content")
           |> hd()
           |> Map.fetch!("marks") == [%{"type" => "bold"}]
  end

  test "executable content, plugin files, embedded images and unsafe URLs skip the question" do
    for html <- [
          "<script>alert(1)</script>",
          "<iframe src='https://example.org'></iframe>",
          "<img src='data:image/png;base64,YWJj'>",
          "<img src='@@PLUGINFILE@@/a.png'>",
          "<a href='javascript:alert(1)'>click</a>"
        ] do
      assert {:skip, _} =
               QuestionImport.safely("Unsafe", fn -> ImportDocument.from(html, "html") end)
    end
  end

  test "lists, table cells and images inside paragraphs become valid block structures" do
    doc =
      ImportDocument.from(
        "<ul><li>Item</li></ul><table><tr><td colspan='2'>Cell</td></tr></table><p>Before<img src='https://example.org/a.png'>After</p>",
        "html"
      )

    assert [list, table, before, image, after_image] = doc["content"]

    assert list["content"] |> hd() |> Map.fetch!("content") |> hd() |> Map.fetch!("type") ==
             "paragraph"

    cell = table["content"] |> hd() |> Map.fetch!("content") |> hd()
    assert cell["attrs"]["colspan"] == 2
    assert hd(cell["content"])["type"] == "paragraph"
    assert ImportDocument.plain(before) == "Before"
    assert image["type"] == "image"
    assert ImportDocument.plain(after_image) == "After"
  end
end
