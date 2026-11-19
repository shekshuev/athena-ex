defmodule Athena.Content.GiftQuestionImport do
  @moduledoc "Parses GIFT records, protecting escaped delimiters before interpreting question syntax."
  alias Athena.Content.{ImportDocument, QuestionImport}

  @escapes %{
    "\\" => "\uE000",
    "~" => "\uE001",
    "=" => "\uE002",
    "#" => "\uE003",
    "{" => "\uE004",
    "}" => "\uE005",
    ":" => "\uE006",
    "n" => "\uE007",
    "[" => "\uE008",
    "]" => "\uE009"
  }

  def parse(data) do
    if Regex.match?(~r/[\x{E000}-\x{E009}]/u, data),
      do: raise(ArgumentError, "Reserved escape marker")

    protected =
      Regex.replace(~r/\\([\\~=\#{}:n\[\]])/u, data, fn _, char -> Map.fetch!(@escapes, char) end)

    protected
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n[\t ]*\n/)
    |> Enum.reduce({[], []}, &parse_chunk/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parse_chunk(chunk, {records, pending}) do
    {comments, lines} =
      chunk
      |> String.split("\n")
      |> Enum.split_with(&String.starts_with?(String.trim_leading(&1), "//"))

    body =
      lines
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "$CATEGORY:"))
      |> Enum.join("\n")
      |> String.trim()

    if body == "" do
      {records, pending ++ comments}
    else
      {title, body} = title(body)

      record =
        QuestionImport.safely(restore(title), fn ->
          parse_record(title, body, pending ++ comments)
        end)

      {[record | records], []}
    end
  end

  defp title("::" <> rest) do
    case String.split(rest, "::", parts: 2) do
      [title, body] -> {title, String.trim(body)}
      _ -> {"", ""}
    end
  end

  defp title(body), do: {"", body}

  defp parse_record(title, body, comments) do
    {format, body} = format(body, "moodle")
    [prompt, answers_and_suffix] = String.split(body, "{", parts: 2)
    [answers, suffix] = String.split(answers_and_suffix, "}", parts: 2)
    {answers, feedback} = split_feedback(answers)
    fields = answer_fields(String.trim(answers), format)
    fields = QuestionImport.with_feedback(fields, document_feedback(feedback, format))
    prompt = prompt <> prompt_suffix(suffix)
    metadata = %{tags: comment_tags(comments)}
    QuestionImport.build(restore(title), document(prompt, format), fields, metadata)
  end

  defp prompt_suffix(suffix) do
    if String.trim(suffix) == "", do: "", else: " _____ " <> suffix
  end

  defp split_feedback(answers) do
    case String.split(answers, "####", parts: 2) do
      [answers, feedback] -> {answers, feedback}
      [answers] -> {answers, ""}
    end
  end

  defp answer_fields("", _format), do: %{"question_type" => "open", "answer_type" => "rich_text"}
  defp answer_fields("#" <> _answers, _format), do: throw({:skip_question, :unsupported_type})

  defp answer_fields(answers, format) do
    cond do
      String.contains?(answers, "~") -> choice_fields(answers, format)
      String.contains?(answers, "->") -> matching_fields(answers, format)
      Regex.match?(~r/^(TRUE|FALSE|T|F)(#|$)/, answers) -> truefalse_fields(answers, format)
      String.contains?(answers, "=") -> shortanswer_fields(answers, format)
      true -> throw({:skip_question, :unsupported_type})
    end
  end

  defp choice_fields(answers, format) do
    type = if String.contains?(answers, "="), do: "single", else: "multiple"
    options = Enum.map(answer_tokens(answers), &choice_option(&1, format))
    %{"question_type" => type, "options" => options}
  end

  defp choice_option({marker, answer}, format) do
    {fraction, text} = weighted(answer, if(marker == "=", do: 100, else: 0))
    {text, feedback} = answer_feedback(text)

    QuestionImport.option(
      document(text, format),
      fraction > 0,
      document_feedback(feedback, format)
    )
  end

  defp shortanswer_fields(answers, format) do
    answers =
      answers
      |> answer_tokens()
      |> Enum.map(fn {_marker, answer} -> weighted(answer, 100) end)
      |> Enum.filter(fn {weight, _text} -> weight > 0 end)

    if length(answers) != 1, do: throw({:skip_question, :answer_pattern})
    [{weight, answer}] = answers
    if weight != 100, do: throw({:skip_question, :answer_pattern})
    {answer, feedback} = answer_feedback(answer)
    {_format, answer} = format(answer, "plain")

    %{
      "question_type" => "exact_match",
      "general_explanation" => document_feedback(feedback, format),
      "correct_answer" => answer |> restore() |> QuestionImport.literal_answer(),
      "case_sensitive" => false
    }
  end

  defp matching_fields(answers, format) do
    pairs =
      Enum.map(answer_tokens(answers), fn {"=", answer} ->
        [left, right] = String.split(answer, "->", parts: 2)

        if String.trim(left) == "" or String.trim(right) == "",
          do: throw({:skip_question, :answer_pattern})

        QuestionImport.pair(
          document(left, format),
          ImportDocument.from(restore(String.trim(right)), "plain")
        )
      end)

    %{"question_type" => "matching", "pairs" => pairs}
  end

  defp truefalse_fields(answers, format) do
    [value | feedback] = String.split(answers, "#", parts: 3)
    correct = value in ["TRUE", "T"]
    {wrong_feedback, correct_feedback} = truefalse_feedback(feedback)

    options =
      Enum.map([true, false], fn value ->
        explanation = if value == correct, do: correct_feedback, else: wrong_feedback

        QuestionImport.option(
          ImportDocument.from(if(value, do: "True", else: "False"), "plain"),
          value == correct,
          document_feedback(explanation, format)
        )
      end)

    %{"question_type" => "single", "options" => options}
  end

  defp truefalse_feedback([]), do: {"", ""}
  defp truefalse_feedback([wrong]), do: {wrong, ""}
  defp truefalse_feedback([wrong, correct]), do: {wrong, correct}

  defp answer_tokens(answers) do
    if not String.starts_with?(String.trim(answers), ["=", "~"]),
      do: raise(ArgumentError, "Missing answer marker")

    Regex.scan(~r/([=~])([^=~]*)/s, answers)
    |> Enum.map(fn [_, marker, text] -> {marker, String.trim(text)} end)
  end

  defp weighted("%" <> rest, _default) do
    [weight, text] = String.split(rest, "%", parts: 2)
    {QuestionImport.number(weight), String.trim(text)}
  end

  defp weighted(answer, default), do: {default, answer}

  defp answer_feedback(answer) do
    case String.split(answer, "#", parts: 2) do
      [answer, feedback] -> {answer, feedback}
      [answer] -> {answer, ""}
    end
  end

  defp format(text, default) do
    text = String.trim(text)

    case Regex.run(~r/^\[(html|plain|moodle|markdown)\](.*)$/s, text) do
      [_, format, rest] -> {format, rest}
      nil -> {default, text}
    end
  end

  defp document(text, default) do
    {format, text} = format(text, default)
    ImportDocument.from(restore(text), format)
  end

  defp document_feedback(text, default) do
    {format, text} = format(text, default)
    ImportDocument.feedback(restore(text), format)
  end

  defp comment_tags(comments) do
    comments
    |> Enum.join("\n")
    |> then(&Regex.scan(~r/\[tag:([^\]]+)\]/, &1))
    |> Enum.map(fn [_, tag] -> restore(tag) end)
    |> Enum.uniq()
  end

  defp restore(text) do
    Enum.reduce(@escapes, text, fn
      {"n", marker}, text -> String.replace(text, marker, "\n")
      {char, marker}, text -> String.replace(text, marker, char)
    end)
  end
end
