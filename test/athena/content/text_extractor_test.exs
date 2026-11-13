defmodule Athena.Content.TextExtractorTest do
  use ExUnit.Case, async: true

  alias Athena.Content.{Block, BlockTypes, TextExtractor}

  describe "extract/1 field allowlist" do
    test "reads a text block as a document, not as a body wrapper" do
      content = doc([paragraph("Текст урока / Elixir")])
      content = Map.put(content, "notes", "HIDDEN_NOTES")

      assert extract(:text, content) == "Текст урока / Elixir"
      assert extract(:text, %{"body" => content}) == ""
    end

    test "reads code instructions and starter code without execution secrets" do
      content = %{
        "body" => doc([paragraph("Вернуть список")]),
        "initial_code" => "def run do\n  # TODO\nend",
        "solution_code" => "SECRET_SOLUTION",
        "setup_sql" => "SECRET_SETUP",
        "check_sql" => "SECRET_CHECK",
        "language" => "SECRET_LANGUAGE",
        "test_cases" => [
          %{"input" => "SECRET_INPUT", "expected_output" => "SECRET_OUTPUT", "is_hidden" => true},
          %{"input" => "PUBLIC_INPUT", "expected_output" => "PUBLIC_OUTPUT", "is_hidden" => false}
        ],
        "notes" => %{"body" => doc([paragraph("SECRET_NOTES")])}
      }

      assert extract(:code, content) == "Вернуть список\ndef run do\n  # TODO\nend"
    end

    test "only extracts the prompt for every question kind" do
      for kind <- ~w(single multiple exact_match open matching) do
        content = %{
          "question_type" => kind,
          "body" => doc([paragraph("Условие вопроса")]),
          "correct_answer" => "SECRET_ANSWER",
          "general_explanation" => "SECRET_EXPLANATION",
          "options" => [
            %{
              "text" => doc([paragraph("OPTION_TEXT")]),
              "is_correct" => true,
              "explanation" => "SECRET_OPTION_EXPLANATION"
            }
          ],
          "pairs" => [
            %{"left" => doc([paragraph("PAIR_LEFT")]), "right" => doc([paragraph("PAIR_RIGHT")])}
          ]
        }

        assert extract(:quiz_question, content) == "Условие вопроса"
      end
    end

    test "excludes protected questions, including legacy string flags" do
      for flag <- [true, "true"] do
        assert extract(:quiz_question, %{
                 "render_prompt_as_image" => flag,
                 "body" => doc([paragraph("PROTECTED_PROMPT")])
               }) == ""
      end

      assert extract(:quiz_question, %{
               "render_prompt_as_image" => false,
               "body" => doc([paragraph("Visible")])
             }) == "Visible"
    end

    test "extracts file assignment instructions without configuration" do
      assert extract(:file_assignment, %{
               "body" => doc([paragraph("Загрузите отчёт")]),
               "max_files" => 10,
               "notes" => "SECRET_NOTES"
             }) == "Загрузите отчёт"
    end

    test "extracts attachment description and file names, never URLs or metadata" do
      assert extract(:attachment, %{
               "description" => doc([paragraph("Материалы")]),
               "files" => [
                 %{"name" => "Учебник.pdf", "url" => "SECRET_URL", "notes" => "SECRET_NOTES"},
                 %{"name" => "data.csv", "content" => "SECRET_FILE_CONTENT"},
                 %{"url" => "ANOTHER_URL"},
                 nil
               ]
             }) == "Материалы\nУчебник.pdf\ndata.csv"
    end

    test "all other current block types are excluded regardless of their payload" do
      excluded = BlockTypes.all() -- [:text, :code, :quiz_question, :file_assignment, :attachment]

      for type <- excluded do
        assert extract(type, %{
                 "body" => doc([paragraph("SECRET_BODY")]),
                 "alt" => "IMAGE_ALT",
                 "title_override" => "SURVEY_TITLE",
                 "description" => doc([paragraph("DESCRIPTION")])
               }) == ""
      end

      assert extract(:unknown, doc([paragraph("UNKNOWN_BLOCK")])) == ""
    end
  end

  describe "Tiptap documents" do
    test "joins inline runs and ignores marks and attributes" do
      text = %{
        "type" => "text",
        "text" => "Enum",
        "marks" => [%{"type" => "link", "attrs" => %{"href" => "SECRET_URL"}}],
        "attrs" => %{"notes" => "SECRET_ATTRIBUTES"}
      }

      assert extract(:text, doc([node("paragraph", [text, text(".reduce/3")])])) ==
               "Enum.reduce/3"
    end

    test "preserves headings, lists, quotes, tables and explicit line breaks" do
      content =
        doc([
          node("heading", [text("Заголовок")]),
          node("paragraph", [text("Строка"), %{"type" => "hardBreak"}, text("Продолжение")]),
          node("bulletList", [node("listItem", [paragraph("Один"), paragraph("Два")])]),
          node("orderedList", [node("listItem", [paragraph("Три")])]),
          node("blockquote", [paragraph("Цитата")]),
          node("table", [
            node("tableRow", [node("tableHeader", [paragraph("Колонка")])]),
            node("tableRow", [
              node("tableCell", [paragraph("A")]),
              node("tableCell", [paragraph("B")])
            ])
          ])
        ])

      assert extract(:text, content) ==
               "Заголовок\nСтрока\nПродолжение\nОдин\nДва\nТри\nЦитата\nКолонка\nA\nB"
    end

    test "preserves code indentation, internal blank lines, case and punctuation" do
      code = "def run do\n  x = %{key: 1}\n\n  Enum.reduce(x, 0, &+/2)\nend"

      assert extract(:text, doc([paragraph("Пример"), node("codeBlock", [text(code)])])) ==
               "Пример\n" <> code
    end

    test "includes visible tips, collapsed details and dialogue lines" do
      content =
        doc([
          node("tip", [paragraph("Подсказка")]),
          node("details", [
            node("detailsSummary", [text("Раскрыть")]),
            node("detailsContent", [paragraph("Доступный текст")])
          ]),
          node("dialogue", [
            Map.put(node("dialogueLine", [text("Реплика")]), "attrs", %{
              "name" => "CHARACTER_METADATA",
              "avatarUrl" => "SECRET_URL"
            })
          ])
        ])

      assert extract(:text, content) == "Подсказка\nРаскрыть\nДоступный текст\nРеплика"
    end

    test "skips entire unknown subtrees and separates their neighbouring text" do
      content =
        doc([
          node("paragraph", [
            text("До"),
            node("instructorNote", [text("SECRET_NOTE")]),
            text("После")
          ]),
          %{"type" => "image", "attrs" => %{"alt" => "IMAGE_ALT", "src" => "SECRET_URL"}},
          node("unknown", [paragraph("SECRET_NESTED_TEXT")]),
          paragraph("Конец")
        ])

      assert extract(:text, content) == "До\nПосле\nКонец"
    end

    test "accepts atom-keyed seed documents without creating atoms" do
      assert extract(:code, %{
               body: %{
                 type: "doc",
                 content: [%{type: "paragraph", content: [%{type: "text", text: "Seed"}]}]
               },
               initial_code: "SELECT 1",
               solution_code: "SECRET"
             }) == "Seed\nSELECT 1"
    end

    test "does not treat malformed structures, HTML or serialized JSON as documents" do
      for content <- [
            nil,
            [],
            "<p>Text</p>",
            Jason.encode!(doc([paragraph("Text")])),
            %{},
            %{"type" => "doc", "content" => "SECRET"},
            %{"type" => "doc", "content" => [nil, 1, %{"type" => "text", "text" => %{}}]}
          ] do
        assert extract(:text, content) == ""
      end

      for type <- [:code, :quiz_question, :file_assignment, :attachment],
          content <- [nil, [], "Text"] do
        assert extract(type, content) == ""
      end

      assert extract(:attachment, %{"files" => %{"name" => "INVALID_FILES"}}) == ""
      assert extract(:code, %{"initial_code" => %{}}) == ""
    end

    test "does not truncate large documents or lose their final paragraphs" do
      paragraphs = for i <- 1..10_000, do: paragraph("Абзац #{i}: Enum.reduce/3")
      expected = Enum.map_join(1..10_000, "\n", &"Абзац #{&1}: Enum.reduce/3")

      assert extract(:text, doc(paragraphs)) == expected
    end
  end

  defp extract(type, content), do: TextExtractor.extract(%Block{type: type, content: content})
  defp doc(children), do: node("doc", children)
  defp paragraph(value), do: node("paragraph", [text(value)])
  defp text(value), do: %{"type" => "text", "text" => value}
  defp node(type, children), do: %{"type" => type, "content" => children}
end
