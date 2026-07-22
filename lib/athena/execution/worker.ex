defmodule Athena.Execution.Worker do
  @moduledoc """
  An Oban worker responsible for asynchronous code challenge execution.

  Fetches the submission and its associated code block, manages the lifecycle
  states (`:processing`, then final execution status), invokes the verification
  sandbox, and broadcasts real-time updates to the frontend via Phoenix PubSub.

  ## Configuration

  The maximum execution time for a single challenge is controlled by the
  `@timeout` module attribute (default: 60_000 ms / 1 minute). If you need
  to tweak it globally, override it via application config:

      config :athena, Athena.Execution.Worker, timeout: 90_000
  """

  use Oban.Worker,
    queue: :code_execution,
    max_attempts: 1

  require Logger

  alias Athena.Repo
  alias Athena.Learning
  alias Athena.Learning.Submission
  alias Athena.Content.{Block, CodeChallenge}
  alias Athena.Execution.{Result, TestResult, Verifier}

  @timeout Application.compile_env(:athena, [Athena.Execution.Worker, :timeout], 60_000)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"submission_id" => id}}) do
    submission = Repo.get!(Submission, id)
    block = Repo.get(Block, submission.block_id)

    challenge = build_challenge(submission, block)
    code = submission.content["code"] || ""
    box_id = System.unique_integer([:positive, :monotonic]) |> rem(10_000)

    result = execute_code(code, challenge, box_id)
    update_submission_with_result(submission, result)
  end

  defp build_challenge(submission, block) do
    challenge_attrs =
      if block do
        block.content
      else
        parent = Repo.get!(Submission, submission.parent_submission_id)

        question =
          Enum.find(parent.content["questions"] || [], &(&1["id"] == submission.block_id))

        question["content"] || %{}
      end

    Ecto.Changeset.apply_changes(CodeChallenge.changeset(%CodeChallenge{}, challenge_attrs))
  end

  defp execute_code(code, challenge, box_id) do
    runner = {:via, :global, :code_runner}

    if :global.whereis_name(:code_runner) != :undefined do
      task =
        Task.Supervisor.async_nolink(
          runner,
          Verifier,
          :verify,
          [code, challenge, box_id]
        )

      try do
        Task.await(task, @timeout)
      catch
        :exit, reason ->
          Logger.error("Remote execution failed: #{inspect(reason)}")
          build_error_result("Runner node crashed or timed out.")
      end
    else
      Logger.error("Runner node is not connected during worker execution!")
      build_error_result("Runner node is not connected!")
    end
  end

  defp build_error_result(message) do
    %Result{
      status: :rejected,
      score: 0,
      time: 0.0,
      memory: 0,
      test_results: [
        %TestResult{
          status: :error,
          expected: "",
          stdout: message,
          stderr: nil,
          input: "",
          time: 0.0,
          memory: 0,
          max_score: 0,
          is_hidden: false
        }
      ]
    }
  end

  defp update_submission_with_result(submission, result) do
    clean_test_results =
      Enum.map(result.test_results, fn tr ->
        tr
        |> Map.from_struct()
        |> Map.new(fn {k, v} ->
          {to_string(k), if(is_atom(v) and not is_boolean(v), do: to_string(v), else: v)}
        end)
      end)

    new_content =
      (submission.content || %{})
      |> Map.put("execution_results", clean_test_results)
      |> Map.delete("is_test_run")

    attrs = %{
      status: :graded,
      score: result.score,
      content: new_content
    }

    case Learning.system_update_submission(submission, attrs) do
      {:ok, _updated_sub} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to update submission: #{inspect(changeset.errors)}")
        :error
    end
  end
end
