defmodule Athena.Surveys.Prompt do
  @moduledoc """
  Flattening a question's TipTap/ProseMirror prompt to plain text.

  Lives in the context rather than in the web layer because the export needs
  it as much as the screen does - a CSV header is a question's text, and two
  implementations of "what does this question say" would eventually disagree
  about which one a reader is looking at.
  """

  @doc """
  The plain text of a TipTap document, with block-level nodes separated by
  spaces. Anything unrecognised yields `""` rather than raising: a prompt is
  author-supplied JSON and a results page must not fall over because of it.
  """
  @spec to_text(term()) :: String.t()
  def to_text(%{"content" => content}) when is_list(content) do
    content |> Enum.map_join(" ", &to_text/1) |> collapse_whitespace()
  end

  def to_text(%{"text" => text}) when is_binary(text), do: text
  def to_text(_doc), do: ""

  defp collapse_whitespace(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim()
  end
end
