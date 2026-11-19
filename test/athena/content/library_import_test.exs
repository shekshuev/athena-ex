defmodule Athena.Content.LibraryImportTest do
  use Athena.DataCase, async: true
  import Athena.Factory
  import Ecto.Query

  alias Athena.{Content, Repo}
  alias Athena.Content.{ImportDocument, LibraryBlock, QuestionExport}

  setup do
    user = insert(:account, role: insert(:role, permissions: ["library.create", "library.read"]))
    %{user: user}
  end

  defp doc(text),
    do: %{
      "type" => "doc",
      "content" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "text" => text}]}]
    }

  defp blocks(user),
    do: Repo.all(from b in LibraryBlock, where: b.owner_id == ^user.id, order_by: b.title)

  defp xml(questions), do: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><quiz>#{questions}</quiz>"

  defp essay(title),
    do:
      "<question type=\"essay\"><name><text>#{title}</text></name><questiontext format=\"html\"><text><![CDATA[<p>Write <b>your</b> answer.</p>]]></text></questiontext><responseformat>plain</responseformat></question>"

  test "both formats round-trip every supported Athena question type", %{user: user} do
    questions =
      [
        {"Single",
         %{
           "question_type" => "single",
           "options" => [
             %{"text" => doc("Right"), "is_correct" => true},
             %{"text" => doc("Wrong"), "is_correct" => false}
           ]
         }},
        {"Multiple",
         %{
           "question_type" => "multiple",
           "options" => [
             %{"text" => doc("First"), "is_correct" => true},
             %{"text" => doc("Second"), "is_correct" => true},
             %{"text" => doc("No"), "is_correct" => false}
           ]
         }},
        {"Exact",
         %{
           "question_type" => "exact_match",
           "correct_answer" => "Lua*",
           "case_sensitive" => false
         }},
        {"Matching",
         %{
           "question_type" => "matching",
           "pairs" => [
             %{"left" => doc("A"), "right" => doc("B")},
             %{"left" => doc("C"), "right" => doc("D")}
           ]
         }},
        {"Open", %{"question_type" => "open", "answer_type" => "rich_text"}}
      ]
      |> Enum.map(fn {title, fields} ->
        %LibraryBlock{
          id: Ecto.UUID.generate(),
          title: title,
          type: :quiz_question,
          points: 7,
          tags: ["nosql", "lecture"],
          content:
            Map.merge(
              %{
                "body" => doc("Код {a=1} ~ # : \\n & <b>"),
                "general_explanation" => "Пояснение & <"
              },
              fields
            )
        }
      end)

    for format <- ["gift", "moodle_xml"] do
      {:ok, data} = QuestionExport.encode(questions, format)

      assert {:ok, %{imported: 5, skipped_count: 0}} =
               Content.import_library_questions(user, data, format)
    end

    imported = blocks(user)
    assert length(imported) == 10
    assert Enum.all?(imported, &(&1.tags == ["nosql", "lecture"] and not &1.is_public))
    assert Enum.all?(imported, &(&1.content["general_explanation"] == "Пояснение & <"))

    assert Enum.all?(
             imported,
             &(ImportDocument.plain(&1.content["body"]) == "Код {a=1} ~ # : \\n & <b>")
           )

    assert Enum.all?(
             Enum.filter(imported, &(&1.title == "Exact")),
             &(&1.content["correct_answer"] == "Lua*")
           )

    assert Enum.all?(
             Enum.filter(imported, &(&1.title == "Multiple")),
             &(Enum.count(&1.content["options"], fn option -> option["is_correct"] end) == 2)
           )

    assert Enum.sort(Enum.map(imported, & &1.points), &<=/2) ==
             List.duplicate(7, 5) ++ List.duplicate(nil, 5)
  end

  test "GIFT handles escaped delimiters, tags, feedback, true/false, missing-word and categories",
       %{user: user} do
    data = ~S"""
    $CATEGORY: Sample

    // [tag:nosql] [tag:lecture]
    ::Escaped \:\: title::[plain]Which \{value\} equals 5? {=2 \+ 3#Yes\#indeed ~6 \= 1#No ####General\: feedback}

    ::True false::Two plus two is four.{TRUE#Wrong#Correct}

    ::Missing word::The capital of France is {=Paris}.
    """

    assert {:ok, %{imported: 3, skipped_count: 0}} =
             Content.import_library_questions(user, data, "gift")

    imported = blocks(user)
    escaped = Enum.find(imported, &(&1.title == "Escaped :: title"))
    assert escaped.tags == ["nosql", "lecture"]
    assert escaped.content["general_explanation"] == "General: feedback"
    assert hd(escaped.content["options"])["explanation"] == "Yes#indeed"
    tf = Enum.find(imported, &(&1.title == "True false"))
    assert hd(tf.content["options"])["is_correct"]
    assert hd(tf.content["options"])["explanation"] == "Correct"
    missing = Enum.find(imported, &(&1.title == "Missing word"))
    assert ImportDocument.plain(missing.content["body"]) =~ "_____ ."
  end

  test "unsupported GIFT questions are skipped independently of valid neighbors", %{user: user} do
    data =
      "::Good one::Write something. {}\n\n::Numeric::How many? {#3:0.1}\n\n::Alternatives::Say yes.{=yes =yep}\n\n::Wildcard::Any word?{=*}\n\n::Broken::No closing brace {=x\n\n::Good two::Done?{=yes}"

    assert {:ok, %{imported: 2, skipped_count: 4, skipped: skipped}} =
             Content.import_library_questions(user, data, "gift")

    assert Enum.map(skipped, & &1.title) == ["Numeric", "Alternatives", "Wildcard", "Broken"]
    assert Enum.map(blocks(user), & &1.title) == ["Good one", "Good two"]
  end

  test "XML preserves tags, integer points, literal exact answer and case sensitivity", %{
    user: user
  } do
    data =
      xml("""
      <question type="shortanswer"><name><text>Exact answer</text></name>
      <questiontext format="plain_text"><text>Type Lua.</text></questiontext>
      <usecase>1</usecase><defaultgrade>4.0000000</defaultgrade>
      <answer fraction="100"><text>Lua</text></answer><answer fraction="0"><text>*</text></answer>
      <tags><tag><text>lecture</text></tag></tags><owner_id>forged</owner_id><is_public>true</is_public></question>
      """)

    assert {:ok, %{imported: 1}} = Content.import_library_questions(user, data, "moodle_xml")
    [question] = blocks(user)
    assert question.points == 4
    assert question.tags == ["lecture"]
    assert question.content["case_sensitive"]
    assert question.content["correct_answer"] == "Lua"
    refute question.is_public
  end

  test "XML skips unsupported question types, embedded media, answer patterns and fractional points",
       %{user: user} do
    data =
      xml("""
      <question type="category"><category><text>Category</text></category></question>
      #{essay("Good one")}
      <question type="numerical"><name><text>Numeric</text></name></question>
      <question type="cloze"><name><text>Cloze</text></name></question>
      <question type="essay"><name><text>File</text></name><file name="a.png">YWJj</file></question>
      <question type="shortanswer"><name><text>Pattern</text></name><answer fraction="100"><text>a*</text></answer></question>
      <question type="essay"><name><text>Fractional</text></name><defaultgrade>0.5</defaultgrade><questiontext><text>Text</text></questiontext></question>
      #{essay("Good two")}
      """)

    assert {:ok, %{imported: 2, skipped_count: 5}} =
             Content.import_library_questions(user, data, "moodle_xml")
  end

  test "malformed XML, DTDs, entity expansion and invalid encodings create no blocks", %{
    user: user
  } do
    data = xml(essay("Never created"))

    for invalid <- [
          data <> "<broken>",
          "<quiz>" <> essay("Never created"),
          "<!DOCTYPE quiz [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><quiz>&x;</quiz>",
          "<!DOCTYPE quiz SYSTEM 'http://127.0.0.1/no-fetch'><quiz/>",
          <<255, 254>>,
          "<quiz>\0</quiz>"
        ] do
      assert {:error, :invalid_file} =
               Content.import_library_questions(user, invalid, "moodle_xml")
    end

    assert blocks(user) == []
  end

  test "unsupported questions alone produce a successful skipped report, not a file failure", %{
    user: user
  } do
    assert {:ok, %{imported: 0, skipped_count: 1}} =
             Content.import_library_questions(user, "::Numeric only::Value? {#2}", "gift")

    assert {:error, :no_questions} =
             Content.import_library_questions(user, "// comment\n\n$CATEGORY: None", "gift")

    assert blocks(user) == []
  end

  test "creation permission is enforced before parsing and imported IDs never overwrite existing questions",
       %{user: user} do
    reader = insert(:account, role: insert(:role, permissions: ["library.read"]))
    assert {:error, :forbidden} = Content.import_library_questions(reader, "bad", "gift")
    existing = insert(:library_block, owner_id: reader.id, title: "Original")
    data = "// [id:#{existing.id}]\n::Imported::Write something. {}"
    assert {:ok, %{imported: 1}} = Content.import_library_questions(user, data, "gift")
    assert Repo.get!(LibraryBlock, existing.id).title == "Original"
    assert [%{owner_id: owner_id, id: id}] = blocks(user)
    assert owner_id == user.id
    refute id == existing.id
  end

  test "import broadcasts library refresh after successful insertion", %{user: user} do
    Phoenix.PubSub.subscribe(Athena.PubSub, "user_library:#{user.id}")

    assert {:ok, %{imported: 1}} =
             Content.import_library_questions(user, "::Imported::Question {}", "gift")

    assert_receive :refresh_library
  end

  test "files and question counts are bounded and UTF-8 BOM is accepted", %{user: user} do
    assert {:ok, %{imported: 1}} =
             Content.import_library_questions(user, "\uFEFF::Imported::Question {}", "gift")

    assert {:error, :file_too_large} =
             Content.import_library_questions(user, String.duplicate("a", 5_000_001), "gift")

    assert {:error, :too_many_questions} =
             Content.import_library_questions(
               user,
               String.duplicate("Question {}\n\n", 2001),
               "gift"
             )

    assert {:error, :invalid_format} = Content.import_library_questions(user, "text", "unknown")
  end

  test "uploaded XML names do not become atoms and deeply nested XML is rejected", %{user: user} do
    name = "uploaded_" <> String.replace(Ecto.UUID.generate(), "-", "")
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    assert {:error, :no_questions} =
             Content.import_library_questions(user, "<quiz><#{name}/></quiz>", "moodle_xml")

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    deep =
      "<quiz>" <>
        String.duplicate("<nested>", 70) <> String.duplicate("</nested>", 70) <> "</quiz>"

    assert {:error, :invalid_file} = Content.import_library_questions(user, deep, "moodle_xml")
  end

  test "large points and tags are skipped before database insertion and CDATA stays literal", %{
    user: user
  } do
    data =
      xml("""
      <question type="essay"><name><text>Too many points</text></name><defaultgrade>1e30</defaultgrade><questiontext><text>Question</text></questiontext></question>
      <question type="essay"><name><text>Long tag</text></name><tags><tag><text>#{String.duplicate("a", 256)}</text></tag></tags><questiontext><text>Question</text></questiontext></question>
      <question type="essay"><name><text>Literal declaration</text></name><questiontext format="plain_text"><text><![CDATA[<!DOCTYPE example>]]></text></questiontext></question>
      """)

    assert {:ok, %{imported: 1, skipped_count: 2}} =
             Content.import_library_questions(user, data, "moodle_xml")

    [question] = blocks(user)
    assert ImportDocument.plain(question.content["body"]) == "<!DOCTYPE example>"
  end

  test "short-answer feedback is retained alongside the general explanation", %{user: user} do
    assert {:ok, %{imported: 1}} =
             Content.import_library_questions(
               user,
               "::GIFT feedback::Question {=Lua#Correct language ####General explanation}",
               "gift"
             )

    data =
      xml(
        "<question type='shortanswer'><name><text>XML feedback</text></name><questiontext><text>Question</text></questiontext><answer fraction='100'><text>Lua</text><feedback><text>Correct language</text></feedback></answer><generalfeedback><text>General explanation</text></generalfeedback></question>"
      )

    assert {:ok, %{imported: 1}} = Content.import_library_questions(user, data, "moodle_xml")

    assert Enum.all?(
             blocks(user),
             &(&1.content["general_explanation"] == "General explanation\n\nCorrect language")
           )
  end
end
