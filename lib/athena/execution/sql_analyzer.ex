defmodule Athena.Execution.SqlAnalyzer do
  @moduledoc """
  Lightweight static analysis of SQL text.

  Used to decide whether row order is part of a query's expected result.
  """

  @doc """
  Returns `true` when the query has an `ORDER BY` clause at the top level.

  Comments, string literals, quoted identifiers and anything nested in
  parentheses (subqueries, `OVER (ORDER BY ...)`, `string_agg(... ORDER BY ...)`)
  are ignored, because those don't fix the order of the final result set.
  """
  @spec top_level_order_by?(String.t() | nil) :: boolean()
  def top_level_order_by?(nil), do: false

  def top_level_order_by?(sql) when is_binary(sql) do
    sql
    |> strip_noise()
    |> top_level_words()
    |> has_order_by?()
  end

  defp has_order_by?(["order", "by" | _]), do: true
  defp has_order_by?([_ | rest]), do: has_order_by?(rest)
  defp has_order_by?([]), do: false

  # Keeps only the words found at parenthesis depth 0, lowercased.
  defp top_level_words(sql) do
    {words, _depth} =
      sql
      |> String.downcase()
      |> String.to_charlist()
      |> Enum.reduce({[], 0}, fn
        ?(, {acc, depth} -> {[" " | acc], depth + 1}
        ?), {acc, depth} -> {[" " | acc], max(depth - 1, 0)}
        ch, {acc, 0} -> {[<<ch::utf8>> | acc], 0}
        _ch, {acc, depth} -> {acc, depth}
      end)

    words |> Enum.reverse() |> Enum.join() |> String.split(~r/\s+/, trim: true)
  end

  defp strip_noise(sql) do
    sql
    |> String.replace(~r/--[^\n]*/, " ")
    |> String.replace(~r{/\*.*?\*/}s, " ")
    |> String.replace(~r/\$\$.*?\$\$/s, " ")
    |> String.replace(~r/'(?:[^']|'')*'/s, " ")
    |> String.replace(~r/"(?:[^"]|"")*"/s, " ")
  end
end
