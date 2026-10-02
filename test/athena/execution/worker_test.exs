defmodule Athena.Execution.WorkerTest do
  use Athena.DataCase, async: true

  import Athena.Factory
  import Ecto.Query

  alias Athena.Content.CompletionRule
  alias Athena.Execution.Worker
  alias Athena.Learning.{BlockProgress, Submission}

  # Without a runner node the worker records a failed check (score 0): that
  # path exercises everything but the sandbox, and must never complete a gate.
  test "a result that does not pass the gate leaves the block uncompleted" do
    student = insert(:account)

    block =
      insert(:block,
        type: :code,
        content: %{"language" => "python", "test_cases" => []},
        completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 60}
      )

    submission =
      insert(:submission,
        account_id: student.id,
        block_id: block.id,
        status: :processing,
        content: %{"type" => "code", "code" => "print(1)"}
      )

    assert :ok = perform_job(Worker, %{submission_id: submission.id})

    assert %Submission{status: :graded, score: 0} = Repo.get!(Submission, submission.id)
    assert Repo.all(from bp in BlockProgress, where: bp.account_id == ^student.id) == []
  end

  test "a passing result completes the block even if nobody is listening" do
    student = insert(:account)

    block =
      insert(:block,
        type: :code,
        completion_rule: %CompletionRule{type: :pass_auto_grade, min_score: 60}
      )

    submission =
      insert(:submission,
        account_id: student.id,
        block_id: block.id,
        status: :processing,
        content: %{"type" => "code", "code" => "print(1)"}
      )

    # No PubSub subscriber anywhere: this is a student whose connection
    # dropped while the code was running.
    result = %Athena.Execution.Result{
      status: :accepted,
      score: 100,
      time: 0.1,
      memory: 0,
      test_results: []
    }

    assert :ok = Worker.update_submission_with_result(submission, result)

    assert [%{status: :completed, block_id: block_id}] =
             Repo.all(from bp in BlockProgress, where: bp.account_id == ^student.id)

    assert block_id == block.id
  end
end
