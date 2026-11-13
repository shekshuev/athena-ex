defmodule Athena.Content.SearchSnippet do
  @moduledoc "Safe bounded snippets; fuzzy locations are approximate and never highlighted."

  @doc "Builds a plain title and text/match segments, without trusted HTML."
  def build(text, query, exact?) do
    regex = Regex.compile!("(" <> Regex.escape(query) <> ")", "iu")

    byte_position =
      case Regex.run(regex, text, return: :index) do
        [{position, _length} | _] -> position
        nil -> fuzzy_position(text, query)
      end

    position = text |> binary_part(0, byte_position) |> String.length()
    context = min(70, max(236 - String.length(query), 0))
    start = max(position - context, 0)
    excerpt = String.slice(text, start, 236)
    excerpt = if start > 0, do: "…" <> excerpt, else: excerpt
    excerpt = if start + 236 < String.length(text), do: excerpt <> "…", else: excerpt

    segments =
      if exact? do
        regex
        |> Regex.split(excerpt, include_captures: true, trim: false)
        |> Enum.with_index()
        |> Enum.map(fn {part, index} -> %{text: part, match?: rem(index, 2) == 1} end)
      else
        [%{text: excerpt, match?: false}]
      end

    title =
      text |> String.trim_leading() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80)

    %{title: title, snippet: segments}
  end

  # word_similarity supplies no positions. Use approximate phrase windows only
  # to choose context; this score never affects ranking or claims exact matches.
  defp fuzzy_position(text, query) do
    tokens =
      Regex.scan(~r/[\p{L}\p{N}_]+/u, text, return: :index) |> Enum.map(&hd/1) |> List.to_tuple()

    count = tuple_size(tokens)
    words = max(length(Regex.scan(~r/[\p{L}\p{N}_]+/u, query)), 1)
    query = String.downcase(query)

    if count == 0 do
      0
    else
      sizes = Enum.uniq([max(words - 1, 1), words, words + 1])

      {_, position} =
        Enum.reduce(0..(count - 1), {-1.0, 0}, fn index, best ->
          best_window_at(text, tokens, query, index, sizes, best)
        end)

      position
    end
  end

  defp best_window_at(text, tokens, query, index, sizes, best) do
    Enum.reduce(sizes, best, fn size, best ->
      score_window(text, tokens, query, index, size, best)
    end)
  end

  defp score_window(text, tokens, query, index, size, {score, _} = best) do
    {start, _} = elem(tokens, index)
    {last, length} = elem(tokens, min(index + size - 1, tuple_size(tokens) - 1))
    window = binary_part(text, start, min(last + length - start, 800))

    # Skip a capped window if its byte boundary splits a UTF-8 character.
    candidate_score =
      if String.valid?(window),
        do: String.jaro_distance(query, String.downcase(window)),
        else: 0.0

    if candidate_score > score, do: {candidate_score, start}, else: best
  end
end
