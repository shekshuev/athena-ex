defmodule Athena.Execution.TestWorker do
  @moduledoc """
  Oban worker for test-running code submissions without consuming formal attempts.
  Updates the draft with execution results and reverts status to :draft.
  """
  use Oban.Worker, queue: :code_execution, max_attempts: 1

  alias Athena.{Repo, Content}
  alias Athena.Learning.{Submission, Submissions}
  alias Athena.Execution.Verifier

  @timeout Application.compile_env(:athena, [Athena.Execution.TestWorker, :timeout], 60_000)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"submission_id" => id}}) do
    submission = Repo.get!(Submission, id)
    block = Repo.get!(Content.Block, submission.block_id)

    {:ok, _} = Submissions.system_update_submission(submission, %{status: :processing})
    broadcast_update(submission)

    challenge_attrs = block.content

    challenge =
      Ecto.Changeset.apply_changes(
        Content.CodeChallenge.changeset(%Content.CodeChallenge{}, challenge_attrs)
      )

    code = submission.content["code"] || ""
    box_id = System.unique_integer([:positive, :monotonic]) |> rem(10_000)

    result =
      if :global.whereis_name(:code_runner) != :undefined do
        task =
          Task.Supervisor.async({:via, :global, :code_runner}, fn ->
            Verifier.verify(code, challenge, box_id)
          end)

        try do
          Task.await(task, @timeout)
        catch
          :exit, reason ->
            require Logger
            Logger.error("Remote test execution failed: #{inspect(reason)}")

            %Verifier.Result{
              status: :rejected,
              score: 0,
              test_results: [
                %{
                  status: :error,
                  expected: "",
                  stdout: "Runner node crashed or timed out.",
                  input: "",
                  time: 0.0,
                  is_hidden: false
                }
              ]
            }
        end
      else
        require Logger
        Logger.error("Runner node is not connected during test worker execution!")

        %Verifier.Result{
          status: :rejected,
          score: 0,
          test_results: [
            %{
              status: :error,
              expected: "",
              stdout: "Runner node is not connected!",
              input: "",
              time: 0.0,
              is_hidden: false
            }
          ]
        }
      end

    clean_test_results =
      Enum.map(result.test_results, fn tr ->
        Map.new(tr, fn {k, v} ->
          {to_string(k), if(is_atom(v) and not is_boolean(v), do: to_string(v), else: v)}
        end)
      end)

    new_content = Map.put(submission.content || %{}, "execution_results", clean_test_results)

    attrs = %{
      status: :draft,
      content: new_content
    }

    case Submissions.system_update_submission(submission, attrs) do
      {:ok, updated_sub} ->
        broadcast_update(updated_sub)
        :ok

      {:error, changeset} ->
        require Logger
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
