defmodule Athena.Content.QuestionExport do
  @moduledoc """
  Serializes individual questions as Moodle GIFT or Moodle XML.
  Standard Moodle multiple choice and matching award partial credit, unlike
  Athena's exact-set grading. GIFT cannot preserve per-question case sensitivity.
  Format reference: https://docs.moodle.org/en/Moodle_XML_format
  """
  alias Athena.Content.ExportDocument, as: Doc

  def encode(blocks, format, opts \\ []) do
    records = Enum.map(blocks, &encode_question(&1, format, opts))

    case Enum.find(records, &match?({:error, _}, &1)) do
      nil ->
        body = Enum.map_join(records, "\n", fn {:ok, text} -> text end)

        body =
          if format == "moodle_xml",
            do: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<quiz>\n#{body}</quiz>\n",
            else: body

        {:ok, body}

      error ->
        error
    end
  end

  defp encode_question(block, format, opts) do
    validate!(block.content)

    text =
      case format do
        "gift" -> gift(block, opts)
        "moodle_xml" -> xml(block, opts)
      end

    {:ok, text}
  rescue
    _ in [ArgumentError, KeyError, FunctionClauseError] ->
      {:error, {:unsupported_question, block.id, block.title}}
  end

  defp validate!(content) do
    if not is_map(content["body"]), do: raise(ArgumentError, "Missing prompt")
    validate_answer!(content)
  end

  defp validate_answer!(%{"question_type" => type} = content)
       when type in ["single", "multiple"] do
    options = content["options"] || []
    validate_choice_count!(type, options)
    Enum.each(options, &validate_option!/1)
  end

  defp validate_answer!(%{"question_type" => "matching"} = content) do
    pairs = content["pairs"] || []
    if length(pairs) < 2, do: raise(ArgumentError, "Missing pairs")
    Enum.each(pairs, &validate_pair!/1)
  end

  defp validate_answer!(%{"question_type" => "exact_match"} = content) do
    if content["correct_answer"] in [nil, ""], do: raise(ArgumentError, "Missing answer")
  end

  defp validate_answer!(%{"question_type" => "open"}), do: :ok
  defp validate_answer!(_content), do: raise(ArgumentError, "Unsupported question type")

  defp validate_choice_count!(type, options) do
    count = Enum.count(options, &(&1["is_correct"] == true))

    if length(options) < 2 or count == 0 or (type == "single" and count != 1),
      do: raise(ArgumentError, "Invalid choices")
  end

  defp validate_option!(option) do
    if not is_map(option["text"]), do: raise(ArgumentError, "Missing choice text")
  end

  defp validate_pair!(pair) do
    if not is_map(pair["left"]) or not is_map(pair["right"]),
      do: raise(ArgumentError, "Missing pair text")
  end

  defp gift(block, opts) do
    content = block.content
    metadata = Enum.map_join(block.tags || [], " ", &"[tag:#{comment(&1)}]")

    "// [id:#{block.id}] #{metadata}\n" <>
      "::#{gift_escape(block.title)}::[html]#{gift_html(content["body"], opts)} {\n" <>
      gift_answers(content, opts) <>
      gift_feedback(content["general_explanation"]) <> "}\n\n"
  end

  defp gift_answers(%{"question_type" => type} = content, opts)
       when type in ["single", "multiple"] do
    Enum.map_join(content["options"], fn option ->
      prefix =
        cond do
          type == "multiple" -> "~%#{weight(option, content)}%"
          option["is_correct"] -> "="
          true -> "~"
        end

      feedback =
        if option["explanation"] in [nil, ""],
          do: "",
          else: "#" <> gift_escape(Doc.escape(option["explanation"]))

      "  #{prefix}#{gift_html(option["text"], opts)}#{feedback}\n"
    end)
  end

  defp gift_answers(%{"question_type" => "matching"} = content, opts) do
    Enum.map_join(content["pairs"], fn pair ->
      # Moodle matching labels on the right are always plain text.
      "  =#{gift_html(pair["left"], opts)} -> #{gift_escape(Doc.plain(pair["right"]))}\n"
    end)
  end

  defp gift_answers(%{"question_type" => "exact_match"} = content, _opts) do
    answer = short_answer(content["correct_answer"])
    # Moodle's GIFT importer uses -> to distinguish matching from short answer.
    if String.contains?(answer, "->"), do: raise(ArgumentError, "Use XML for this answer")
    "  =[plain]#{gift_escape(answer)}\n"
  end

  defp gift_answers(%{"question_type" => "open"}, _opts), do: ""

  defp gift_feedback(value) when value in [nil, ""], do: ""
  defp gift_feedback(value), do: "  #####{gift_escape(Doc.escape(value))}\n"

  defp gift_html(doc, opts), do: doc |> Doc.html(opts) |> gift_escape()

  defp gift_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(["~", "=", "#", "{", "}", ":"], fn char -> "\\" <> char end)
    |> String.replace("\r", "")
    |> String.replace("\n", "\\n")
  end

  defp comment(value),
    do: value |> String.replace(~r/[\r\n\x00-\x1F]/, " ") |> String.replace("]", "\\]")

  defp xml(block, opts) do
    content = block.content

    type =
      case content["question_type"] do
        type when type in ["single", "multiple"] -> "multichoice"
        "exact_match" -> "shortanswer"
        "matching" -> "matching"
        "open" -> "essay"
      end

    "<question type=\"#{type}\">\n" <>
      element("name", element("text", Doc.escape(block.title))) <>
      element("idnumber", Doc.escape(block.id)) <>
      html_element("questiontext", Doc.html(content["body"], opts)) <>
      html_element("generalfeedback", Doc.escape(content["general_explanation"] || "")) <>
      element("defaultgrade", to_string(block.points || 100)) <>
      element("penalty", "0") <>
      xml_answers(content, opts) <>
      element(
        "tags",
        Enum.map_join(block.tags || [], &element("tag", element("text", Doc.escape(&1))))
      ) <>
      "</question>\n"
  end

  defp xml_answers(%{"question_type" => type} = content, opts)
       when type in ["single", "multiple"] do
    element("single", to_string(type == "single")) <>
      element("shuffleanswers", "0") <>
      element("answernumbering", "abc") <>
      Enum.map_join(content["options"], fn option ->
        "<answer fraction=\"#{weight(option, content)}\" format=\"html\">" <>
          element("text", cdata(Doc.html(option["text"], opts))) <>
          html_element("feedback", Doc.escape(option["explanation"] || "")) <>
          "</answer>\n"
      end)
  end

  defp xml_answers(%{"question_type" => "exact_match"} = content, _opts) do
    element("usecase", if(content["case_sensitive"], do: "1", else: "0")) <>
      "<answer fraction=\"100\" format=\"plain_text\">" <>
      element("text", Doc.escape(short_answer(content["correct_answer"]))) <> "</answer>\n"
  end

  defp xml_answers(%{"question_type" => "matching"} = content, opts) do
    element("shuffleanswers", "0") <>
      Enum.map_join(content["pairs"], fn pair ->
        "<subquestion format=\"html\">" <>
          element("text", cdata(Doc.html(pair["left"], opts))) <>
          element("answer", element("text", Doc.escape(Doc.plain(pair["right"])))) <>
          "</subquestion>\n"
      end)
  end

  defp xml_answers(%{"question_type" => "open"} = content, _opts) do
    element(
      "responseformat",
      if(content["answer_type"] == "rich_text", do: "editor", else: "plain")
    ) <>
      element("responserequired", "1") <>
      element("responsefieldlines", "15") <>
      element("attachments", "0") <>
      element("attachmentsrequired", "0")
  end

  # In Moodle short answers, * is a wildcard unless escaped.
  defp short_answer(answer), do: String.replace(answer, "*", "\\*")

  defp weight(%{"is_correct" => true}, %{"question_type" => "single"}), do: "100"
  defp weight(_option, %{"question_type" => "single"}), do: "0"

  defp weight(%{"is_correct" => true}, content) do
    correct = Enum.count(content["options"], &(&1["is_correct"] == true))
    :erlang.float_to_binary(100 / correct, decimals: 7)
  end

  defp weight(_option, _content), do: "-100"

  defp element(name, value), do: "<#{name}>#{value}</#{name}>\n"

  defp html_element(name, value),
    do: "<#{name} format=\"html\">#{element("text", cdata(value))}</#{name}>\n"

  defp cdata(value), do: "<![CDATA[" <> String.replace(value, "]]>", "]]]]><![CDATA[>") <> "]]>"
end
