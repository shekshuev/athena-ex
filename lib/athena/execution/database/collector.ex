defmodule Athena.Execution.Database.Collector do
  @moduledoc "Collects driver chunks under a total deadline and shared SQL output budgets."
  alias Athena.Execution.Database.{Limits, Result}

  def collect(stream, seconds) do
    deadline = System.monotonic_time(:millisecond) + trunc(seconds * 1_000)
    limits = Limits.config()

    state =
      Enum.reduce(
        stream,
        Map.put(Limits.initial(), :result, nil),
        &collect_chunk(&1, &2, limits, deadline)
      )

    chunk = state.result

    {:ok,
     %Result{
       columns: chunk.columns,
       rows: if(is_nil(chunk.columns), do: nil, else: Enum.reverse(state.rows)),
       num_rows: if(is_nil(chunk.columns), do: chunk.num_rows, else: state.count)
     }}
  catch
    {:sql_collection, reason} -> {:error, reason}
  end

  defp collect_chunk(chunk, state, limits, deadline) do
    check_deadline(deadline)

    if is_nil(chunk.columns) and Map.get(chunk, :data, []) not in [nil, [], ""] do
      throw({:sql_collection, {:sql_error, "Custom SQL output formats are not supported."}})
    end

    Enum.reduce(
      chunk.rows || [],
      %{state | result: chunk},
      &collect_row(&1, &2, limits, deadline)
    )
  end

  defp collect_row(row, state, limits, deadline) do
    check_deadline(deadline)

    case Limits.collect(row, state, limits) do
      {:ok, next} -> Map.put(next, :result, state.result)
      {:error, reason} -> throw({:sql_collection, reason})
    end
  end

  defp check_deadline(deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: throw({:sql_collection, :timeout})
  end
end
