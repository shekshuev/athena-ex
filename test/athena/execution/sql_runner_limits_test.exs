defmodule Athena.Execution.SqlRunnerLimitsTest do
  use ExUnit.Case, async: false

  alias Athena.Content.CodeChallenge
  alias Athena.Execution.{SqlRunner, Verifier}

  setup do
    previous = Application.fetch_env!(:athena, SqlRunner)

    Application.put_env(
      :athena,
      SqlRunner,
      Keyword.merge(previous,
        max_result_rows: 3,
        max_result_bytes: 1_000,
        max_row_bytes: 100,
        max_cell_bytes: 50,
        stream_max_rows: 2
      )
    )

    on_exit(fn -> Application.put_env(:athena, SqlRunner, previous) end)
    %{box_id: System.unique_integer([:positive, :monotonic]) + 100_000_000}
  end

  test "accepts exactly the row limit, preserving columns, order and total count", context do
    assert {:ok, %Postgrex.Result{rows: [[1], [2], [3]], num_rows: 3, columns: ["n"]}} =
             query(context, "SELECT generate_series(1, 3) AS n")

    assert {:ok, %Postgrex.Result{rows: [], num_rows: 0, columns: ["n"]}} =
             query(context, "SELECT 1 AS n WHERE false")
  end

  test "rejects the first extra row even when it matches the start of the reference", context do
    assert {:error, {:result_limit_exceeded, "SQL result exceeds 3 rows."}} =
             query(context, "SELECT generate_series(1, 4)")
  end

  test "counts JSON escaping and UTF-8 in cells", context do
    assert {:ok, _} = query(context, "SELECT repeat('я', 24)")

    assert {:error, {:result_limit_exceeded, "SQL result exceeds 50 bytes per cell."}} =
             query(context, "SELECT repeat('я', 25)")

    assert {:error, {:result_limit_exceeded, _}} =
             query(context, "SELECT repeat(chr(10), 25)")
  end

  test "bounds JSON and binary values after the same conversion used for display", context do
    assert {:error, {:result_limit_exceeded, _}} =
             query(context, "SELECT jsonb_build_object('value', repeat('x', 60))")

    assert {:error, {:result_limit_exceeded, _}} =
             query(context, "SELECT decode(repeat('00', 30), 'hex')")
  end

  test "bounds a row even when every cell is individually small", context do
    assert {:ok, _} = query(context, "SELECT repeat('x', 47), repeat('y', 46)")

    assert {:error, {:result_limit_exceeded, "SQL result exceeds 100 bytes per row."}} =
             query(context, "SELECT repeat('x', 48), repeat('y', 48)")
  end

  test "counts array brackets and commas across chunks in the result budget", context do
    configure(max_result_bytes: 13)
    assert {:ok, _} = query(context, "SELECT n FROM generate_series(1, 3) AS n")

    configure(max_result_bytes: 12)

    assert {:error, {:result_limit_exceeded, "SQL result exceeds 12 bytes per result."}} =
             query(context, "SELECT n FROM generate_series(1, 3) AS n")
  end

  test "rolls back rejected RETURNING and leaves the connection usable", context do
    assert {:ok, :checked} =
             SqlRunner.execute_in_sandbox(context.box_id, "CREATE TABLE t (n int)", fn conn ->
               assert {:error, {:result_limit_exceeded, _}} =
                        SqlRunner.query(
                          conn,
                          "INSERT INTO t SELECT generate_series(1,4) RETURNING n",
                          2
                        )

               assert {:ok, %{rows: [[0]]}} = SqlRunner.query(conn, "SELECT count(*) FROM t", 2)

               assert {:ok, %{rows: nil, num_rows: 4}} =
                        SqlRunner.query(conn, "INSERT INTO t SELECT generate_series(1,4)", 2)

               assert {:ok, %{rows: [[4]]}} = SqlRunner.query(conn, "SELECT count(*) FROM t", 2)
               :checked
             end)
  end

  test "enforces a total deadline across fetches", context do
    configure(max_result_rows: 100)

    assert {:error, :timeout} =
             query(context, "SELECT pg_sleep(0.03) FROM generate_series(1,20)", 0.12)
  end

  test "applies output limits to teacher setup SQL too", context do
    assert {:error, {:setup_error, "SQL result exceeds 3 rows."}} =
             SqlRunner.execute_in_sandbox(context.box_id, "SELECT generate_series(1,4)", fn _ ->
               flunk("Oversized setup must not run the callback")
             end)
  end

  test "reference overflow is a preparation error and does not execute the student", context do
    challenge = %CodeChallenge{
      language: "sql",
      solution_code: "SELECT generate_series(1,4)",
      time_limit: 2.0
    }

    result = Verifier.verify("SELECT 1/0", challenge, context.box_id)
    assert result.status == :compilation_error
    assert [test_result] = result.test_results
    assert test_result.stderr == "Reference Solution Error: SQL result exceeds 3 rows."
    assert Jason.decode!(test_result.stdout)["status"] == "result_limit_exceeded"
  end

  test "student overflow produces only a small error payload", context do
    challenge = %CodeChallenge{language: "sql", solution_code: "SELECT 1", time_limit: 2.0}
    result = Verifier.verify("SELECT generate_series(1,4)", challenge, context.box_id)
    assert result.status == :memory_limit_exceeded
    assert result.score == 0
    assert [test_result] = result.test_results
    payload = Jason.decode!(test_result.stdout)
    assert payload["stderr"] == "SQL result exceeds 3 rows."
    refute Map.has_key?(payload, "rows")
    refute Map.has_key?(payload, "expected_rows")
  end

  test "state verification limits both student output and teacher check output", context do
    challenge = %CodeChallenge{
      language: "sql",
      evaluation_mode: "state_verification",
      check_sql: "SELECT 'OK'",
      time_limit: 2.0
    }

    result = Verifier.verify("SELECT generate_series(1,4)", challenge, context.box_id)
    assert result.status == :memory_limit_exceeded

    result =
      Verifier.verify(
        "SELECT 1",
        %{challenge | check_sql: "SELECT repeat('x', 60)"},
        context.box_id
      )

    assert result.status == :memory_limit_exceeded
    assert [test_result] = result.test_results
    assert test_result.stderr =~ "bytes per cell"
  end

  defp query(context, sql, timeout \\ 2.0) do
    assert {:ok, result} =
             SqlRunner.execute_in_sandbox(context.box_id, nil, fn conn ->
               SqlRunner.query(conn, sql, timeout)
             end)

    result
  end

  defp configure(overrides) do
    Application.put_env(
      :athena,
      SqlRunner,
      Keyword.merge(Application.fetch_env!(:athena, SqlRunner), overrides)
    )
  end
end
