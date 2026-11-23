defmodule Athena.Execution.Database.Statements do
  @moduledoc "Splits MySQL/ClickHouse setup statements; never treats quoted semicolons as separators."

  def split(sql, dialect \\ "mysql")

  def split(sql, dialect) when is_binary(sql),
    do: scan(sql, :normal, [], %{dialect: dialect, statements: []})

  def split(_, _), do: {:error, {:sql_error, "SQL must be text."}}

  def single(sql, dialect \\ "mysql") do
    case split(sql, dialect) do
      {:ok, [statement]} -> {:ok, statement}
      {:ok, _} -> {:error, {:sql_error, "Exactly one SQL statement is required."}}
      error -> error
    end
  end

  defp scan(<<>>, state, current, statements) when state in [:normal, :line] do
    {:ok, Enum.reverse(add(current, statements).statements)}
  end

  defp scan(<<>>, _, _, _), do: {:error, {:sql_error, "Unterminated SQL quote or comment."}}

  # MySQL executable comments must not hide a second statement or override limits.
  defp scan(<<"/*!", _::binary>>, :normal, _, _),
    do: {:error, {:sql_error, "Executable comments are not supported."}}

  defp scan(<<"/*M!", _::binary>>, :normal, _, _),
    do: {:error, {:sql_error, "Executable comments are not supported."}}

  # In MySQL -- needs following whitespace; 1--1 means subtraction.
  defp scan(<<"--", char, rest::binary>>, :normal, current, %{dialect: "mysql"} = acc)
       when char > 32,
       do: scan(<<char, rest::binary>>, :normal, ["--" | current], acc)

  defp scan(<<"--", rest::binary>>, :normal, current, acc),
    do: scan(rest, :line, [" " | current], acc)

  defp scan(<<"#", rest::binary>>, :normal, current, acc),
    do: scan(rest, :line, [" " | current], acc)

  defp scan(<<"/*", rest::binary>>, :normal, current, acc),
    do: scan(rest, {:comment, 1}, [" " | current], acc)

  defp scan(<<"/*", rest::binary>>, {:comment, depth}, current, acc),
    do: scan(rest, {:comment, depth + 1}, current, acc)

  defp scan(<<"*/", rest::binary>>, {:comment, 1}, current, acc),
    do: scan(rest, :normal, current, acc)

  defp scan(<<"*/", rest::binary>>, {:comment, depth}, current, acc),
    do: scan(rest, {:comment, depth - 1}, current, acc)

  defp scan(<<_, rest::binary>>, {:comment, _} = state, current, acc),
    do: scan(rest, state, current, acc)

  defp scan(<<"\n", rest::binary>>, :line, current, acc),
    do: scan(rest, :normal, ["\n" | current], acc)

  defp scan(<<_, rest::binary>>, :line, current, acc), do: scan(rest, :line, current, acc)

  defp scan(<<";", rest::binary>>, :normal, current, acc),
    do: scan(rest, :normal, [], add(current, acc))

  defp scan(<<quote, rest::binary>>, :normal, current, acc) when quote in [?', ?", ?`],
    do: scan(rest, {:quote, quote}, [<<quote>> | current], acc)

  defp scan(<<"\\", char, rest::binary>>, {:quote, _} = state, current, acc),
    do: scan(rest, state, [<<?\\, char>> | current], acc)

  defp scan(<<quote, quote, rest::binary>>, {:quote, quote}, current, acc),
    do: scan(rest, {:quote, quote}, [<<quote, quote>> | current], acc)

  defp scan(<<quote, rest::binary>>, {:quote, quote}, current, acc),
    do: scan(rest, :normal, [<<quote>> | current], acc)

  defp scan(<<char, rest::binary>>, state, current, acc),
    do: scan(rest, state, [<<char>> | current], acc)

  def words(statement) do
    statement
    |> unquoted_text()
    |> String.upcase()
    |> String.split(~r/[^A-Z_]+/, trim: true)
  end

  def unquoted_text(statement) do
    statement |> unquoted(:normal, []) |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp unquoted(<<>>, _, acc), do: acc

  defp unquoted(<<quote, rest::binary>>, :normal, acc) when quote in [?', ?", ?`],
    do: unquoted(rest, {:quote, quote}, [" " | acc])

  defp unquoted(<<"\\", _, rest::binary>>, {:quote, _} = state, acc),
    do: unquoted(rest, state, acc)

  defp unquoted(<<quote, quote, rest::binary>>, {:quote, quote}, acc),
    do: unquoted(rest, {:quote, quote}, acc)

  defp unquoted(<<quote, rest::binary>>, {:quote, quote}, acc), do: unquoted(rest, :normal, acc)
  defp unquoted(<<_, rest::binary>>, {:quote, _} = state, acc), do: unquoted(rest, state, acc)

  defp unquoted(<<char, rest::binary>>, :normal, acc),
    do: unquoted(rest, :normal, [<<char>> | acc])

  defp add(current, %{statements: statements} = acc) do
    next =
      case current |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim() do
        "" -> statements
        statement -> [statement | statements]
      end

    %{acc | statements: next}
  end
end
