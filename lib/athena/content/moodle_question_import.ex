defmodule Athena.Content.MoodleQuestionImport do
  @moduledoc "Imports the individual Moodle XML question types representable by Athena."
  alias Athena.Content.{ImportDocument, ImportXml, QuestionImport}

  def parse(data) do
    case ImportXml.parse(data) do
      %{name: "quiz"} = quiz ->
        quiz
        |> ImportXml.children("question")
        |> Enum.reject(&(type(&1) == "category"))
        |> Enum.map(&parse_question/1)

      _ ->
        raise ArgumentError, "Expected a Moodle quiz"
    end
  end

  defp parse_question(node) do
    title = node |> ImportXml.child("name") |> ImportXml.field("text")

    QuestionImport.safely(title, fn ->
      reject_files!(node)
      fields = node |> type() |> fields(node)

      fields =
        QuestionImport.with_feedback(fields, feedback(ImportXml.child(node, "generalfeedback")))

      metadata = %{
        tags: tags(node),
        points: QuestionImport.points(ImportXml.field(node, "defaultgrade"))
      }

      QuestionImport.build(
        title,
        document(ImportXml.child(node, "questiontext")),
        fields,
        metadata
      )
    end)
  end

  defp fields("multichoice", node) do
    type = if ImportXml.field(node, "single") in ["false", "0"], do: "multiple", else: "single"
    %{"question_type" => type, "options" => options(node)}
  end

  defp fields("truefalse", node), do: %{"question_type" => "single", "options" => options(node)}

  defp fields("shortanswer", node) do
    answers = Enum.filter(ImportXml.children(node, "answer"), &(fraction(&1) > 0))
    if length(answers) != 1, do: throw({:skip_question, :answer_pattern})
    [answer] = answers
    if fraction(answer) != 100, do: throw({:skip_question, :answer_pattern})

    %{
      "question_type" => "exact_match",
      "general_explanation" => feedback(ImportXml.child(answer, "feedback")),
      "correct_answer" => answer |> ImportXml.field("text") |> QuestionImport.literal_answer(),
      "case_sensitive" => ImportXml.field(node, "usecase") == "1"
    }
  end

  defp fields("matching", node) do
    pairs = Enum.map(ImportXml.children(node, "subquestion"), &matching_pair/1)
    %{"question_type" => "matching", "pairs" => pairs}
  end

  defp fields("essay", node) do
    reject_attachments!(node)

    %{
      "question_type" => "open",
      "answer_type" => answer_type(ImportXml.field(node, "responseformat"))
    }
  end

  defp fields(_type, _node), do: throw({:skip_question, :unsupported_type})

  defp options(node) do
    Enum.map(ImportXml.children(node, "answer"), fn answer ->
      QuestionImport.option(
        document(answer),
        fraction(answer) > 0,
        feedback(ImportXml.child(answer, "feedback"))
      )
    end)
  end

  defp matching_pair(node) do
    left = document(node)
    right = node |> ImportXml.child("answer") |> ImportXml.field("text")

    if String.trim(ImportDocument.plain(left)) == "" or right == "",
      do: throw({:skip_question, :answer_pattern})

    QuestionImport.pair(left, ImportDocument.from(right, "plain"))
  end

  defp answer_type(format) when format in ["", "editor", "editorfilepicker"], do: "rich_text"
  defp answer_type(format) when format in ["plain", "monospaced"], do: "plain_text"
  defp answer_type(_format), do: throw({:skip_question, :unsupported_format})

  defp reject_attachments!(node) do
    if ImportXml.field(node, "attachments") not in ["", "0"],
      do: throw({:skip_question, :embedded_files})
  end

  defp reject_files!(node) do
    if ImportXml.contains?(node, "file"), do: throw({:skip_question, :embedded_files})

    if String.contains?(ImportXml.text(node), "@@PLUGINFILE@@"),
      do: throw({:skip_question, :embedded_files})
  end

  defp tags(node),
    do:
      node
      |> ImportXml.child("tags")
      |> ImportXml.children("tag")
      |> Enum.map(&ImportXml.field(&1, "text"))

  defp fraction(node), do: node |> ImportXml.attr("fraction", "0") |> QuestionImport.number()
  defp type(node), do: ImportXml.attr(node, "type", "")
  defp document(nil), do: raise(ArgumentError, "Missing question text")

  defp document(node),
    do: ImportDocument.from(ImportXml.field(node, "text"), ImportXml.attr(node, "format", "html"))

  defp feedback(nil), do: ""

  defp feedback(node),
    do:
      ImportDocument.feedback(
        ImportXml.field(node, "text"),
        ImportXml.attr(node, "format", "html")
      )
end
