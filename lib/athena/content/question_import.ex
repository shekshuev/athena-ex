defmodule Athena.Content.QuestionImport do
  @moduledoc "Shared normalization and per-question failure handling for library imports."
  alias Athena.Content.ImportDocument, as: Doc

  def safely(title, fun) do
    {:ok, fun.()}
  rescue
    _ in [ArgumentError, FunctionClauseError, KeyError, MatchError] ->
      {:skip, %{title: title, reason: :invalid_question}}
  catch
    {:skip_question, reason} -> {:skip, %{title: title, reason: reason}}
  end

  def build(title, body, fields, metadata \\ %{}) do
    title = String.trim(title)
    title = if title == "", do: body |> Doc.plain() |> String.slice(0, 255), else: title
    title = if String.length(title) < 3, do: "Imported question: " <> title, else: title
    validate_choices!(fields)

    %{
      "title" => title,
      "type" => "quiz_question",
      "tags" => normalize_tags(Map.get(metadata, :tags, [])),
      "points" => Map.get(metadata, :points),
      "content" => Map.merge(%{"body" => body, "answer_type" => "plain_text"}, fields)
    }
  end

  def option(doc, correct, explanation \\ ""),
    do: %{
      "id" => Ecto.UUID.generate(),
      "text" => doc,
      "is_correct" => correct,
      "explanation" => explanation
    }

  def pair(left, right), do: %{"id" => Ecto.UUID.generate(), "left" => left, "right" => right}

  def with_feedback(fields, text) do
    feedback =
      [text, Map.get(fields, "general_explanation", "")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.join("\n\n")

    Map.put(fields, "general_explanation", feedback)
  end

  def literal_answer(text) do
    # Moodle treats an unescaped * as a wildcard; Athena has literal exact answers.
    if Regex.match?(~r/(?<!\\)\*/, text), do: throw({:skip_question, :answer_pattern})
    String.replace(text, "\\*", "*")
  end

  def number(text) do
    case Float.parse(String.trim(text)) do
      {value, ""} -> value
      _ -> raise ArgumentError, "Invalid number"
    end
  end

  def points(""), do: nil

  def points(text) do
    value = number(text)
    if value > 2_147_483_647, do: throw({:skip_question, :invalid_question})
    if value <= 0 or trunc(value) != value, do: throw({:skip_question, :fractional_points})
    trunc(value)
  end

  defp normalize_tags(tags) do
    tags = tags |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    if Enum.any?(tags, &(String.length(&1) > 255)), do: throw({:skip_question, :invalid_question})
    tags
  end

  defp validate_choices!(%{"question_type" => type, "options" => options})
       when type in ["single", "multiple"] do
    correct = Enum.count(options, & &1["is_correct"])
    if length(options) < 2 or correct == 0, do: throw({:skip_question, :invalid_question})
    if type == "single" and correct != 1, do: throw({:skip_question, :answer_pattern})
  end

  defp validate_choices!(_fields), do: :ok
end
