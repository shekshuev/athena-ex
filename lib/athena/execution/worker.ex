defmodule Athena.Execution.Worker do
  @moduledoc """
  An Oban worker responsible for asynchronous code challenge execution.

  Fetches the submission and its associated code block, manages the lifecycle
  states (`:processing`, then final execution status), invokes the verification
  sandbox, and broadcasts real-time updates to the frontend via Phoenix PubSub.
  """

  use Oban.Worker,
    queue: :code_execution,
    max_attempts: 1

  alias Athena.Repo
  alias Athena.Learning.{Submission, Submissions}
  alias Athena.Content.{Block, CodeChallenge}
  alias Athena.Execution.Verifier

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

    result = Verifier.verify(code, challenge, box_id)

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
