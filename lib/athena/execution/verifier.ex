defmodule Athena.Execution.Verifier do
  @moduledoc """
  High-level logic to verify a submission against multiple test cases.
  Aggregates results and calculates the final score.
  """
  alias Athena.Execution.IsolateRunner
  alias Athena.Execution.LanguageConfig
  alias Athena.Content.CodeChallenge
  alias Athena.Content.TestCase

  defmodule Result do
    @moduledoc """
    Represents the final aggregated result of a verification run.
    """
    defstruct [:status, :score, :time, :memory, :test_results]

    @type t :: %__MODULE__{
            status: atom(),
            score: integer(),
            time: float(),
            memory: integer(),
            test_results: [map()]
          }
  end

  @doc """
  Verifies the given code against a list of test cases.
  Compiles the code ONCE, then runs it against all tests.
  """
  @spec verify(String.t(), CodeChallenge.t(), integer()) :: Result.t()
  def verify(code, %CodeChallenge{} = challenge, box_id) do
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
  @spec run_single_test(TestCase.t(), IsolateRunner.Context.t()) :: map()
  defp run_single_test(test, ctx) do
    case IsolateRunner.run_execution(test.input, ctx) do
      {:ok, run_info} ->
        evaluate_test(run_info, test)

      {:error, _} ->
        %{status: :system_error, score: 0, time: 0.0, memory: 0}
    end
  end

  defp build_compile_error_result(stderr) do
    %Result{
      status: :compilation_error,
      score: 0,
      time: 0.0,
      memory: 0,
      test_results: [
        %{status: :compilation_error, stderr: stderr, score: 0}
      ]
    }
  end

  defp build_system_error_result do
    %Result{status: :system_error, score: 0, time: 0.0, memory: 0, test_results: []}
  end

  @doc false
  @spec evaluate_test(map(), TestCase.t()) :: map()
  defp evaluate_test(%{meta: meta, stdout: stdout, stderr: stderr}, test) do
    status = determine_status(meta, stdout, test.expected_output)
    score = if status == :accepted, do: test.weight, else: 0

    %{
      status: status,
      score: score,
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
  @spec summarize([map()]) :: Result.t()
  defp summarize(results) do
    total_score = results |> Enum.map(& &1.score) |> Enum.sum()
    max_time = results |> Enum.map(& &1.time) |> Enum.max(fn -> 0.0 end)
    max_mem = results |> Enum.map(& &1.memory) |> Enum.max(fn -> 0 end)

    final_status =
      results
      |> Enum.find(%{status: :accepted}, fn r -> r.status != :accepted end)
      |> Map.get(:status)

    %Result{
      status: final_status,
      score: total_score,
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
