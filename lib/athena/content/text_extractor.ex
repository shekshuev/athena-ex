defmodule Athena.Content.TextExtractor do
  @moduledoc """
  Extracts student-facing search text from a block without database access.

  Only explicitly allowed fields and Tiptap nodes are read. Answers, quiz
  options and pairs, explanations, execution configuration, and protected
  prompts are excluded. Exams, images, videos, and surveys produce no text.

  Unsupported or malformed values are skipped, including entire unknown
  node subtrees. Attributes and marks are never searched. Documents must be
  Tiptap maps; serialized JSON and HTML are not interpreted as documents.
  Atom-keyed documents built by seeds are supported alongside JSONB maps.

  Paragraph boundaries become newlines, adjacent inline runs stay joined,
  and whitespace inside text runs (including source code) is preserved.
  Only leading and trailing whitespace of the final result is trimmed.
  """

  alias Athena.Content.Block

  @container_nodes ~w(doc bulletList orderedList blockquote tip details detailsContent dialogue)
  @block_nodes ~w(paragraph heading codeBlock listItem table tableRow tableCell tableHeader detailsSummary dialogueLine)

  @doc "Returns the block's indexable text, or an empty string when none is available."
  @spec extract(Block.t()) :: String.t()
  def extract(%Block{type: :text, content: content}), do: document(content)

  def extract(%Block{type: :code, content: content}) when is_map(content) do
    join_parts([document(fetch(content, :body)), plain_text(fetch(content, :initial_code))])
  end

  def extract(%Block{type: :quiz_question, content: content}) when is_map(content) do
    if fetch(content, :render_prompt_as_image) in [true, "true"] do
      ""
    else
      document(fetch(content, :body))
    end
  end

  def extract(%Block{type: :file_assignment, content: content}) when is_map(content),
    do: document(fetch(content, :body))

  def extract(%Block{type: :attachment, content: content}) when is_map(content) do
    names =
      case fetch(content, :files) do
        files when is_list(files) -> Enum.map(files, &file_name/1)
        _ -> []
      end

    join_parts([document(fetch(content, :description)) | names])
  end

  def extract(%Block{}), do: ""

  defp document(value) when is_map(value) do
    if fetch(value, :type) == "doc" do
      {tokens, _boundary?} =
        value
        |> node_tokens()
        |> List.flatten()
        |> Enum.reduce({[], true}, fn
          :boundary, {tokens, true} -> {tokens, true}
          :boundary, {tokens, false} -> {["\n" | tokens], true}
          "", acc -> acc
          text, {tokens, _boundary?} -> {[text | tokens], false}
        end)

      tokens |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
    else
      ""
    end
  end

  defp document(_), do: ""

  defp node_tokens(node) when is_map(node) do
    case fetch(node, :type) do
      "text" -> plain_text(fetch(node, :text))
      "hardBreak" -> "\n"
      type when type in @container_nodes -> child_tokens(node)
      type when type in @block_nodes -> [child_tokens(node), :boundary]
      _ -> :boundary
    end
  end

  defp node_tokens(_), do: :boundary

  defp child_tokens(node) do
    case fetch(node, :content) do
      children when is_list(children) -> Enum.map(children, &node_tokens/1)
      _ -> []
    end
  end

  defp file_name(file) when is_map(file), do: plain_text(fetch(file, :name))
  defp file_name(_), do: ""

  defp plain_text(value) when is_binary(value), do: value
  defp plain_text(_), do: ""

  defp join_parts(parts) do
    parts |> Enum.reject(&(&1 == "")) |> Enum.join("\n") |> String.trim()
  end

  defp fetch(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end
end
