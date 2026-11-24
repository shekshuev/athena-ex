defmodule Athena.Execution.Database.Limits do
  @moduledoc "Shared SQL result budgets, measured using the same JSON cells as the result viewer."
  alias Athena.Execution.SqlValue

  def config, do: Application.fetch_env!(:athena, Athena.Execution.SqlRunner)
  def initial, do: %{rows: [], count: 0, bytes: 2}

  def collect(row, state, limits) do
    cells = Enum.map(row, &SqlValue.to_cell/1)
    row_bytes = size(cells)
    bytes = state.bytes + row_bytes + if(state.count == 0, do: 0, else: 1)
    count = state.count + 1

    with :ok <- check(count, limits, :max_result_rows, "rows"),
         :ok <- check_cells(cells, limits),
         :ok <- check(row_bytes, limits, :max_row_bytes, "bytes per row"),
         :ok <- check(bytes, limits, :max_result_bytes, "bytes per result") do
      {:ok, %{rows: [row | state.rows], count: count, bytes: bytes}}
    end
  end

  def validate(result) do
    Enum.reduce_while(result.rows || [], {:ok, initial()}, fn row, {:ok, state} ->
      case collect(row, state, config()) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> {:ok, result}
      error -> error
    end
  end

  defp check_cells(cells, limits) do
    Enum.reduce_while(cells, :ok, fn cell, :ok ->
      case check(size(cell), limits, :max_cell_bytes, "bytes per cell") do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check(value, limits, key, unit) do
    maximum = Keyword.fetch!(limits, key)

    if value > maximum,
      do: {:error, {:result_limit_exceeded, "SQL result exceeds #{maximum} #{unit}."}},
      else: :ok
  end

  defp size(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()
end
