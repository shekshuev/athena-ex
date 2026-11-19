defmodule Athena.Content.QuestionExportTest do
  use ExUnit.Case, async: true

  import SweetXml
  alias Athena.Content.{LibraryBlock, QuestionExport}

  defp doc(text),
    do: %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}]
    }

  defp question(type, attrs \\ %{}) do
    %LibraryBlock{
      id: Ecto.UUID.generate(),
      title: "Вопрос :: {1}",
      type: :quiz_question,
      tags: ["nosql", "lecture"],
      points: 7,
      content:
        Map.merge(
          %{
            "question_type" => type,
            "body" => doc("Код {a=1} ~ # : \\n & <b> ]]>"),
            "general_explanation" => "Пояснение < &"
          },
          attrs
        )
    }
  end

  defp choices do
    Enum.map(
      1..4,
      &%{"text" => doc("Вариант #{&1}"), "is_correct" => &1 < 4, "explanation" => "Почему #{&1}"}
    )
  end

  test "XML is well formed and preserves question types, tags, weights, feedback and settings" do
    blocks = [
      question("single", %{
        "options" => [
          %{"text" => doc("Да"), "is_correct" => true},
          %{"text" => doc("Нет"), "is_correct" => false}
        ]
      }),
      question("multiple", %{"options" => choices()}),
      question("exact_match", %{"correct_answer" => "Lua*", "case_sensitive" => true}),
      question("matching", %{
        "pairs" => [
          %{"left" => doc("A"), "right" => doc("B")},
          %{"left" => doc("C"), "right" => doc("D")}
        ]
      }),
      question("open", %{"answer_type" => "plain_text"}),
      question("open", %{"answer_type" => "rich_text"})
    ]

    assert {:ok, body} = QuestionExport.encode(blocks, "moodle_xml")
    parsed = SweetXml.parse(body)

    assert xpath(parsed, ~x"//question/@type"sl) == [
             "multichoice",
             "multichoice",
             "shortanswer",
             "matching",
             "essay",
             "essay"
           ]

    assert xpath(parsed, ~x"//question[1]/defaultgrade/text()"s) == "7"
    assert xpath(parsed, ~x"//question[1]/tags/tag/text/text()"sl) == ["nosql", "lecture"]
    assert xpath(parsed, ~x"//question[3]/usecase/text()"s) == "1"
    assert xpath(parsed, ~x"//question[3]/answer/text/text()"s) == "Lua\\*"
    assert xpath(parsed, ~x"//question[4]/subquestion/answer/text/text()"sl) == ["B", "D"]
    assert xpath(parsed, ~x"//question[5]/responseformat/text()"s) == "plain"
    assert xpath(parsed, ~x"//question[6]/responseformat/text()"s) == "editor"
    assert xpath(parsed, ~x"//question[1]/questiontext/text/text()"s) =~ "&lt;b&gt; ]]&gt;"

    weights =
      xpath(parsed, ~x"//question[2]/answer/@fraction"sl)
      |> Enum.map(fn value ->
        {number, ""} = Float.parse(value)
        number
      end)

    assert_in_delta Enum.sum(Enum.filter(weights, &(&1 > 0))), 100, 0.00001
    assert List.last(weights) == -100.0
    assert xpath(parsed, ~x"//question[2]/answer[1]/feedback/text/text()"s) == "Почему 1"
  end

  test "GIFT escapes authored syntax and preserves tags, feedback and multiple selection" do
    assert {:ok, body} =
             QuestionExport.encode([question("multiple", %{"options" => choices()})], "gift")

    assert body =~ "[tag:nosql] [tag:lecture]"
    assert body =~ "::Вопрос \\:\\: \\{1\\}::[html]"
    assert body =~ "\\{a\\=1\\} \\~ \\# \\:"
    assert length(Regex.scan(~r/~%33\.3333333%/, body)) == 3
    assert body =~ "~%-100%"
    assert body =~ "#Почему 1"
    assert body =~ "####Пояснение &lt; &amp;"
  end

  test "matching right labels are plain text in GIFT, and open questions have no answer" do
    block =
      question("matching", %{
        "pairs" => [
          %{"left" => doc("A -> X"), "right" => doc("B")},
          %{"left" => doc("C"), "right" => doc("D")}
        ]
      })

    assert {:ok, body} = QuestionExport.encode([block, question("open")], "gift")
    assert body =~ "=<p>A -&gt; X</p> -> B"
    assert body =~ "=<p>C</p> -> D"
    assert length(Regex.scan(~r/^::/m, body)) == 2
  end

  test "unrepresentable and incomplete content fails instead of silently omitting questions" do
    block = question("open", %{"body" => %{"type" => "futureWidget"}})
    assert {:error, {:unsupported_question, _, _}} = QuestionExport.encode([block], "gift")

    assert {:error, {:unsupported_question, _, _}} =
             QuestionExport.encode([question("single", %{"options" => []})], "moodle_xml")

    assert {:error, {:unsupported_question, _, _}} =
             QuestionExport.encode(
               [question("exact_match", %{"correct_answer" => "a->b"})],
               "gift"
             )
  end

  test "portable HTML keeps code, links and absolute image references without fetching URLs" do
    body = %{
      "type" => "doc",
      "content" => [
        %{"type" => "codeBlock", "content" => [%{"type" => "text", "text" => "a < b\n{}"}]},
        %{"type" => "image", "attrs" => %{"src" => "/media/library/a.png", "alt" => "<picture>"}},
        %{
          "type" => "paragraph",
          "content" => [
            %{
              "type" => "text",
              "text" => "File",
              "marks" => [%{"type" => "link", "attrs" => %{"href" => "/media/library/file.pdf"}}]
            }
          ]
        }
      ]
    }

    assert {:ok, xml} =
             QuestionExport.encode([question("open", %{"body" => body})], "moodle_xml",
               base_url: "https://athena.example"
             )

    prompt = xpath(xml, ~x"//questiontext/text/text()"s)
    assert prompt =~ "<pre><code>a &lt; b\n{}</code></pre>"
    assert prompt =~ "https://athena.example/media/library/a.png"
    assert prompt =~ "alt=\"&lt;picture&gt;\""
    assert prompt =~ "href=\"https://athena.example/media/library/file.pdf\""
  end

  test "XML gives unweighted questions the same default weight as Athena exams" do
    block = %{question("open") | points: nil}
    assert {:ok, xml} = QuestionExport.encode([block], "moodle_xml")
    assert xpath(xml, ~x"//defaultgrade/text()"s) == "100"
  end

  test "missing option text and unsafe links fail with the question identity" do
    block =
      question("multiple", %{"options" => [%{"is_correct" => true}, %{"is_correct" => false}]})

    assert {:error, {:unsupported_question, _, _}} = QuestionExport.encode([block], "gift")

    doc = %{
      "type" => "text",
      "text" => "link",
      "marks" => [%{"type" => "link", "attrs" => %{"href" => "java\nscript:alert(1)"}}]
    }

    assert {:error, {:unsupported_question, _, _}} =
             QuestionExport.encode([question("open", %{"body" => doc})], "moodle_xml")
  end
end
