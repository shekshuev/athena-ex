defmodule Athena.Execution.MulticodeWorkerTest do
  use Athena.DataCase, async: true
  import Athena.Factory
  alias Athena.{Learning, Repo}
  alias Athena.Execution.{Worker, TestWorker}
  alias Athena.Learning.Submission

  test "both workers reject an unavailable language before sandbox execution" do
    block = insert(:block, type: :multicode, content: %{"languages" => %{"python3" => %{}}})

    for worker <- [Worker, TestWorker] do
      sub =
        insert(:submission,
          block_id: block.id,
          status: :draft,
          content: %{"type" => "multicode", "language" => "sql", "code" => "SELECT 1"}
        )

      assert :ok = perform_job(worker, %{submission_id: sub.id})
      stored = Repo.get!(Submission, sub.id)

      assert [%{"status" => "error", "stdout" => "Programming language is unavailable."}] =
               stored.content["execution_results"]
    end
  end

  test "generated exam questions validate the chosen language against the snapshot" do
    student = insert(:account)
    question_id = Ecto.UUID.generate()

    parent =
      insert(:submission,
        account_id: student.id,
        content: %{
          "questions" => [
            %{
              "id" => question_id,
              "type" => "multicode",
              "content" => %{
                "languages" => %{
                  "javascript" => %{
                    "solution_code" => "console.log(1)",
                    "test_cases" => [%{"expected_output" => "1", "weight" => 100}]
                  }
                }
              }
            }
          ]
        }
      )

    assert {:error, :unavailable_language} =
             Learning.save_question_submission(
               parent,
               student.id,
               question_id,
               nil,
               %{"type" => "multicode", "language" => "sql", "code" => "SELECT 1"}
             )

    assert {:ok, child} =
             Learning.save_question_submission(
               parent,
               student.id,
               question_id,
               nil,
               %{"type" => "multicode", "language" => "javascript", "code" => "console.log(1)"}
             )

    assert child.content["language"] == "javascript"

    # System writes can restore legacy/invalid answers; the worker independently
    # rechecks the immutable question snapshot before invoking the verifier.
    {:ok, child} =
      Learning.system_update_submission(child, %{
        content: %{"language" => "sql", "code" => "SELECT 1"}
      })

    assert :ok = perform_job(Worker, %{submission_id: child.id})
    assert Repo.get!(Submission, child.id).score == 0
  end
end
