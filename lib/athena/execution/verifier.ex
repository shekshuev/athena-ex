defmodule Athena.Execution.Verifier do
  @moduledoc """
  High-level logic to verify a submission against multiple test cases or SQL verifiers.
  Aggregates results and calculates the final score as a percentage.
  """
  alias Athena.Content.{CodeChallenge, TestCase}
  alias Athena.Execution.{Result, TestResult, IsolateRunner, SqlRunner, LanguageConfig}

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
    with {:ok, expected_res} <- SqlRunner.query(conn, solution_sql, time_limit),
         {:ok, actual_res} <- SqlRunner.query(conn, student_sql, time_limit) do
      if normalize_sql_result(expected_res) == normalize_sql_result(actual_res) do
        {:ok, :accepted, "Query result matches expected output."}
      else
        {:error, :wrong_answer, "Result set does not match the expected data."}
      end
    else
      {:error, :timeout} ->
        {:error, :time_limit_exceeded, "Query execution timed out."}

      {:error, {:sql_error, msg}} ->
        {:error, :runtime_error, msg}

      {:error, {:system_error, reason}} ->
        {:error, :system_error, inspect(reason)}
    end
  end

  defp evaluate_sql_state(conn, student_sql, check_sql, time_limit) do
    with {:ok, _} <- SqlRunner.query(conn, student_sql, time_limit),
         {:ok, check_res} <- SqlRunner.query(conn, check_sql, time_limit) do
      case check_res.rows do
        [["OK"]] ->
          {:ok, :accepted, "State verification passed."}

        [[error_msg]] ->
          {:error, :wrong_answer, to_string(error_msg)}

        _ ->
          {:error, :wrong_answer, "Check script did not return 'OK'."}
      end
    else
      {:error, :timeout} ->
        {:error, :time_limit_exceeded, "Query execution timed out."}

      {:error, {:sql_error, msg}} ->
        {:error, :runtime_error, msg}

      {:error, {:system_error, reason}} ->
        {:error, :system_error, inspect(reason)}
    end
  end

  defp normalize_sql_result(%Postgrex.Result{columns: cols, rows: rows}) do
    {cols || [], Enum.sort(rows || [])}
  end

  defp format_sql_execution_result({:ok, {:ok, status, message}}) do
    build_sql_result(status, message)
  end

  defp format_sql_execution_result({:ok, {:error, status, message}}) do
    build_sql_result(status, message)
  end

  defp format_sql_execution_result({:error, {:setup_error, msg}}) do
    build_sql_result(:compilation_error, "Setup SQL Error: #{msg}")
  end

  defp format_sql_execution_result({:error, {:system_error, reason}}) do
    build_sql_result(:system_error, "Database error: #{inspect(reason)}")
  end

  defp build_sql_result(status, message) do
    score = if status == :accepted, do: 100, else: 0

    %Result{
      status: status,
      score: score,
      time: 0.01,
      memory: 1024,
      test_results: [
        %TestResult{
          status: status,
          score: score,
          max_score: 100,
          stdout: if(status == :accepted, do: message, else: ""),
          stderr: if(status != :accepted, do: message, else: nil),
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
