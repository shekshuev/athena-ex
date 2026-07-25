defmodule Athena.Execution.Verifier do
  @moduledoc """
  High-level logic to verify a submission against multiple test cases or SQL verifiers.
  Aggregates results and calculates the final score as a percentage.
  """
  alias Athena.Content.{CodeChallenge, TestCase}
  alias Athena.Execution.{LanguageConfig, IsolateRunner, Result, SqlRunner, TestResult}

  @doc """
  Verifies the given code against test cases or SQL evaluation rules.
  """
  @spec verify(String.t(), CodeChallenge.t(), integer()) :: Result.t()
  def verify(code, %CodeChallenge{language: "sql"} = challenge, box_id),
    do: verify_sql(code, challenge, box_id)

  def verify(code, %CodeChallenge{} = challenge, box_id),
    do: verify_isolate(code, challenge, box_id)

  defp verify_sql(code, challenge, box_id) do
    setup_sql = get_challenge_field(challenge, :setup_sql)
    eval_mode = get_challenge_field(challenge, :evaluation_mode) || "query_result"
    time_limit = challenge.time_limit || 2.0

    execution_res =
      SqlRunner.execute_in_sandbox(box_id, setup_sql, fn conn ->
        case to_string(eval_mode) do
          "query_result" ->
            solution_sql = get_challenge_field(challenge, :solution_sql)
            evaluate_sql_query_result(conn, code, solution_sql, time_limit)

          "state_verification" ->
            check_sql = get_challenge_field(challenge, :check_sql)
            evaluate_sql_state(conn, code, check_sql, time_limit)

          mode ->
            {:error, {:system_error, "Unknown SQL evaluation mode: #{mode}"}}
        end
      end)

    format_sql_execution_result(execution_res)
  end

  defp evaluate_sql_query_result(conn, student_sql, solution_sql, time_limit) do
    {_t_ref, ref_res} = :timer.tc(fn -> SqlRunner.query(conn, solution_sql, time_limit) end)
    {t_stu, student_res} = :timer.tc(fn -> SqlRunner.query(conn, student_sql, time_limit) end)

    time_sec = Float.round(t_stu / 1_000_000, 3)

    compare_query_results(ref_res, student_res, time_sec)
  end

  defp compare_query_results({:ok, ref_out}, {:ok, stu_out}, time_sec) do
    if normalize_sql_result(ref_out) == normalize_sql_result(stu_out) do
      {:ok, :accepted, build_query_payload("accepted", stu_out, ref_out, time_sec)}
    else
      {:error, :wrong_answer, build_query_payload("wrong_answer", stu_out, ref_out, time_sec)}
    end
  end

  defp compare_query_results({:error, {:sql_error, msg}}, _stu_res, time_sec) do
    {:error, :compilation_error,
     build_sql_query_error("sql_error", "Reference Solution Error: #{msg}", time_sec)}
  end

  defp compare_query_results(_ref_res, {:error, :timeout}, time_sec) do
    {:error, :time_limit_exceeded,
     build_sql_query_error("timeout", "Query execution timed out.", time_sec)}
  end

  defp compare_query_results(_ref_res, {:error, {:sql_error, msg}}, time_sec) do
    {:error, :runtime_error, build_sql_query_error("sql_error", msg, time_sec)}
  end

  defp compare_query_results(_ref_res, {:error, {:system_error, reason}}, time_sec) do
    {:error, :system_error, build_sql_query_error("system_error", inspect(reason), time_sec)}
  end

  defp compare_query_results(_ref_res, _stu_res, time_sec) do
    {:error, :system_error,
     build_sql_query_error("system_error", "Failed to execute SQL comparison.", time_sec)}
  end

  defp build_query_payload(status, stu_out, ref_out, time_sec) do
    %{
      "type" => "sql_query",
      "status" => status,
      "columns" => stu_out.columns || [],
      "rows" => sanitize_rows(stu_out.rows || []),
      "expected_columns" => ref_out.columns || [],
      "expected_rows" => sanitize_rows(ref_out.rows || []),
      "time" => time_sec
    }
  end

  defp build_sql_query_error(status, stderr, time_sec) do
    %{"type" => "sql_query", "status" => status, "stderr" => stderr, "time" => time_sec}
  end

  defp evaluate_sql_state(conn, student_sql, check_sql, time_limit) do
    {t_stu, student_res} = :timer.tc(fn -> SqlRunner.query(conn, student_sql, time_limit) end)
    time_sec = Float.round(t_stu / 1_000_000, 3)

    with {:ok, _} <- student_res,
         {:ok, check_res} <- SqlRunner.query(conn, check_sql, time_limit) do
      case check_res.rows do
        [["OK"]] ->
          payload = %{
            "type" => "sql_state",
            "status" => "accepted",
            "message" => "State verification passed.",
            "time" => time_sec
          }

          {:ok, :accepted, payload}

        [[error_msg]] ->
          payload = %{
            "type" => "sql_state",
            "status" => "wrong_answer",
            "message" => to_string(error_msg),
            "time" => time_sec
          }

          {:error, :wrong_answer, payload}

        _ ->
          payload = %{
            "type" => "sql_state",
            "status" => "wrong_answer",
            "message" => "Check script did not return 'OK'.",
            "time" => time_sec
          }

          {:error, :wrong_answer, payload}
      end
    else
      {:error, :timeout} ->
        {:error, :time_limit_exceeded,
         %{
           "type" => "sql_state",
           "status" => "timeout",
           "stderr" => "Query execution timed out.",
           "time" => time_sec
         }}

      {:error, {:sql_error, msg}} ->
        {:error, :runtime_error,
         %{"type" => "sql_state", "status" => "sql_error", "stderr" => msg, "time" => time_sec}}

      {:error, {:system_error, reason}} ->
        {:error, :system_error,
         %{
           "type" => "sql_state",
           "status" => "system_error",
           "stderr" => inspect(reason),
           "time" => time_sec
         }}
    end
  end

  defp sanitize_rows(rows) when is_list(rows) do
    Enum.map(rows, fn row ->
      row
      |> row_to_list()
      |> Enum.map(&sanitize_cell/1)
    end)
  end

  defp sanitize_rows(_), do: []

  defp row_to_list(row) when is_tuple(row), do: Tuple.to_list(row)
  defp row_to_list(row) when is_list(row), do: row
  defp row_to_list(row), do: [row]

  defp sanitize_cell(nil), do: "NULL"
  defp sanitize_cell(val) when is_binary(val), do: val
  defp sanitize_cell(val) when is_number(val) or is_boolean(val), do: val
  defp sanitize_cell(val), do: to_string(val)

  defp normalize_sql_result(%Postgrex.Result{columns: cols, rows: rows}) do
    {cols || [], Enum.sort(rows || [])}
  end

  defp format_sql_execution_result({:ok, {:ok, status, payload}}) when is_map(payload) do
    build_sql_result(status, payload)
  end

  defp format_sql_execution_result({:ok, {:error, status, payload}}) when is_map(payload) do
    build_sql_result(status, payload)
  end

  defp format_sql_execution_result({:error, {:setup_error, msg}}) do
    build_sql_result(:compilation_error, %{
      "type" => "sql_state",
      "status" => "sql_error",
      "stderr" => "Setup SQL Error: #{msg}"
    })
  end

  defp format_sql_execution_result({:error, {:system_error, reason}}) do
    build_sql_result(:system_error, %{
      "type" => "sql_state",
      "status" => "system_error",
      "stderr" => "Database error: #{inspect(reason)}"
    })
  end

  defp build_sql_result(status, %{} = payload) do
    score = if status == :accepted, do: 100, else: 0

    %Result{
      status: status,
      score: score,
      time: Map.get(payload, "time", 0.01),
      memory: 1024,
      test_results: [
        %TestResult{
          status: status,
          score: score,
          max_score: 100,
          stdout: Jason.encode!(payload),
          stderr: payload["stderr"],
          expected: "OK",
          input: "",
          is_hidden: false
        }
      ]
    }
  end

  defp get_challenge_field(%CodeChallenge{} = challenge, field) do
    Map.get(challenge, field) || Map.get(challenge.body || %{}, to_string(field))
  end

  defp verify_isolate(code, %CodeChallenge{} = challenge, box_id) do
    lang_config = LanguageConfig.get(challenge.language)

    ctx = %IsolateRunner.Context{
      box_id: box_id,
      lang_config: lang_config,
      time_limit: challenge.time_limit,
      memory_limit: challenge.memory_limit
    }

    try do
      case IsolateRunner.setup_sandbox(code, ctx) do
        {:ok, ready_ctx} ->
          results = Enum.map(challenge.test_cases, &run_single_test(&1, ready_ctx))
          summarize(results)

        {:error, {:compilation_error, stderr}} ->
          build_compile_error_result(stderr)

        {:error, _reason} ->
          build_system_error_result()
      end
    after
      IsolateRunner.cleanup(ctx)
    end
  end

  @doc false
  @spec run_single_test(TestCase.t(), IsolateRunner.Context.t()) :: TestResult.t()
  defp run_single_test(test, ctx) do
    case IsolateRunner.run_execution(test.input, ctx) do
      {:ok, run_info} ->
        evaluate_test(run_info, test)

      {:error, _} ->
        %TestResult{
          status: :system_error,
          score: 0,
          max_score: test.weight,
          time: 0.0,
          memory: 0,
          stdout: "",
          stderr: nil,
          input: test.input,
          expected: test.expected_output,
          is_hidden: test.is_hidden
        }
    end
  end

  defp build_compile_error_result(stderr) do
    %Result{
      status: :compilation_error,
      score: 0,
      time: 0.0,
      memory: 0,
      test_results: [
        %TestResult{
          status: :compilation_error,
          stderr: stderr,
          score: 0,
          max_score: 0,
          time: 0.0,
          memory: 0,
          stdout: "",
          input: "",
          expected: "",
          is_hidden: false
        }
      ]
    }
  end

  defp build_system_error_result do
    %Result{status: :system_error, score: 0, time: 0.0, memory: 0, test_results: []}
  end

  @doc false
  @spec evaluate_test(map(), TestCase.t()) :: TestResult.t()
  defp evaluate_test(%{meta: meta, stdout: stdout, stderr: stderr}, test) do
    status = determine_status(meta, stdout, test.expected_output)
    score = if status == :accepted, do: test.weight, else: 0

    %TestResult{
      status: status,
      score: score,
      max_score: test.weight,
      time: String.to_float(meta["time"] || "0.0"),
      memory: String.to_integer(meta["cg-mem"] || "0"),
      stdout: stdout,
      stderr: stderr,
      input: test.input,
      expected: test.expected_output,
      is_hidden: test.is_hidden
    }
  end

  @doc false
  @spec determine_status(map(), String.t(), String.t()) :: atom()
  defp determine_status(meta, stdout, expected) do
    cond do
      meta["status"] == "CE" -> :compilation_error
      meta["status"] == "TO" -> :time_limit_exceeded
      meta["status"] == "SG" -> :memory_limit_exceeded
      meta["status"] == "RE" -> :runtime_error
      meta["exitcode"] != "0" -> :runtime_error
      normalize(stdout) == normalize(expected) -> :accepted
      true -> :wrong_answer
    end
  end

  @doc false
  @spec summarize([TestResult.t()]) :: Result.t()
  defp summarize(results) do
    earned_score = results |> Enum.map(& &1.score) |> Enum.sum()
    total_possible = results |> Enum.map(& &1.max_score) |> Enum.sum()

    final_score =
      if total_possible > 0 do
        round(earned_score / total_possible * 100)
      else
        0
      end

    max_time = results |> Enum.map(& &1.time) |> Enum.max(fn -> 0.0 end)
    max_mem = results |> Enum.map(& &1.memory) |> Enum.max(fn -> 0 end)

    final_status =
      results
      |> Enum.find(%TestResult{status: :accepted}, fn r -> r.status != :accepted end)
      |> Map.get(:status)

    %Result{
      status: final_status,
      score: final_score,
      time: max_time,
      memory: max_mem,
      test_results: results
    }
  end

  @doc false
  @spec normalize(String.t() | nil) :: String.t()
  defp normalize(nil), do: ""

  defp normalize(text) do
    text
    |> String.trim()
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end
end
