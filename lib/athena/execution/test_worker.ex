defmodule Athena.Execution.TestWorker do
  @moduledoc """
  Oban worker for test-running code submissions without consuming formal attempts.
  Updates the draft with execution results and reverts status to :draft.
  """
  use Oban.Worker, queue: :code_execution, max_attempts: 1

  require Logger

  alias Athena.{Repo, Content}
  alias Athena.Learning
  alias Athena.Learning.Submission
  alias Athena.Execution.{Result, TestResult, Verifier}

  @timeout Application.compile_env(:athena, [Athena.Execution.TestWorker, :timeout], 60_000)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"submission_id" => id}}) do
    submission = Repo.get!(Submission, id)
    block = Repo.get!(Content.Block, submission.block_id)

    {:ok, processing_sub} = Learning.system_update_submission(submission, %{status: :processing})

    challenge_attrs = block.content

    challenge =
      Ecto.Changeset.apply_changes(
        Content.CodeChallenge.changeset(%Content.CodeChallenge{}, challenge_attrs)
      )

    code = processing_sub.content["code"] || ""
    box_id = System.unique_integer([:positive, :monotonic]) |> rem(10_000)

    result =
      if :global.whereis_name(:code_runner) != :undefined do
        runner = {:via, :global, :code_runner}

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
            Logger.error("Remote test execution failed: #{inspect(reason)}")

            %Result{
              status: :rejected,
              score: 0,
              time: 0.0,
              memory: 0,
              test_results: [
                %TestResult{
                  status: :error,
                  expected: "",
                  stdout: "Runner node crashed or timed out.",
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
      else
        Logger.error("Runner node is not connected during test worker execution!")

        %Result{
          status: :rejected,
          score: 0,
          time: 0.0,
          memory: 0,
          test_results: [
            %TestResult{
              status: :error,
              expected: "",
              stdout: "Runner node is not connected!",
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

    clean_test_results =
      Enum.map(result.test_results, fn tr ->
        tr
        |> Map.from_struct()
        |> Map.new(fn {k, v} ->
          {to_string(k), if(is_atom(v) and not is_boolean(v), do: to_string(v), else: v)}
        end)
      end)

    new_content = Map.put(processing_sub.content || %{}, "execution_results", clean_test_results)

    attrs = %{
      status: :draft,
      content: new_content
    }

    case Learning.system_update_submission(processing_sub, attrs) do
      {:ok, updated_sub} ->
        broadcast_update(updated_sub)
        :ok

      {:error, changeset} ->
        Logger.error("Failed to update test submission: #{inspect(changeset.errors)}")
        :error
    end
  end

  defp broadcast_update(submission) do
    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "submission:#{submission.account_id}:#{submission.block_id}",
      {:draft_updated,
       %{
         block_id: submission.block_id,
         content: submission.content,
         updater_id: "test_worker"
       }}
    )
  end
end
