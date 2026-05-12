defmodule Athena.Execution.Worker do
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

    box_id = System.unique_integer([:positive, :monotonic]) |> rem(10000)

    result = Verifier.verify(code, challenge, box_id)

    attrs = %{
      status: result.status,
      score: result.score,
      feedback: Jason.encode!(result.test_results)
    }

    {:ok, updated_sub} = Submissions.system_update_submission(submission, attrs)

    broadcast_update(updated_sub)

    :ok
  end

  defp broadcast_update(submission) do
    Phoenix.PubSub.broadcast(
      Athena.PubSub,
      "submission:#{submission.account_id}:#{submission.block_id}",
      {:submission_updated, submission}
    )
  end
end
