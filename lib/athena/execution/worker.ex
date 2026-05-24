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

  alias Athena.Repo
  alias Athena.Learning.{Submission, Submissions}
  alias Athena.Content.{Block, CodeChallenge}
  alias Athena.Execution.Verifier

  @timeout Application.compile_env(:athena, [Athena.Execution.Worker, :timeout], 60_000)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"submission_id" => id}}) do
    submission = Repo.get!(Submission, id)
    block = Repo.get!(Block, submission.block_id)

    {:ok, submission} = Submissions.system_update_submission(submission, %{status: :processing})
    broadcast_update(submission)

    challenge_attrs = block.content

    challenge =
      Ecto.Changeset.apply_changes(CodeChallenge.changeset(%CodeChallenge{}, challenge_attrs))

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
            Logger.error("Remote execution failed: #{inspect(reason)}")

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
        Logger.error("Runner node is not connected during worker execution!")

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
      status: result.status,
      score: result.score,
      content: new_content
    }

    case Submissions.system_update_submission(submission, attrs) do
      {:ok, updated_sub} ->
        broadcast_update(updated_sub)
        :ok

      {:error, changeset} ->
        require Logger
        Logger.error("Failed to update submission: #{inspect(changeset.errors)}")
        :error
    end
  end

  defp broadcast_update(submission) do
    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "submission:#{submission.account_id}:#{submission.block_id}",
      {:submission_updated, submission}
    )
  end
end
