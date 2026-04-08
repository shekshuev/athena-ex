defmodule Athena.Learning.EvaluatorTest do
  use Athena.DataCase, async: true

  alias Athena.Learning.Evaluator
  alias Athena.Learning.SubmissionContent
  import Athena.Factory

  describe "evaluate_sync/1 for single quiz_question" do
    setup do
      section = insert(:section)
      account = insert(:account)
      %{section: section, account: account}
    end

    test "returns empty map if submission is not pending", %{account: account, section: section} do
      block = insert(:block, section: section, type: :quiz_question)

      submission =
        insert(:submission, account_id: account.id, block_id: block.id, status: :graded)

      assert Evaluator.evaluate_sync(submission) == %{}
    end

    test "grades exact_match (case insensitive by default)", %{account: account, section: section} do
      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "correct_answer" => "athena{h4ck3d}"
          }
        )

      submission =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          content: %SubmissionContent{
            type: :quiz_question,
            text_answer: " ATHENA{H4CK3D} "
          }
        )

      result = Evaluator.evaluate_sync(submission)

      assert result.status == :graded
      assert result.score == 100
    end

    test "grades exact_match (case sensitive)", %{account: account, section: section} do
      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{
            "question_type" => "exact_match",
            "correct_answer" => "athena{h4ck3d}",
            "case_sensitive" => true
          }
        )

      sub_wrong =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          content: %SubmissionContent{
            type: :quiz_question,
            text_answer: "ATHENA{h4ck3d}"
          }
        )

      sub_correct =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          content: %SubmissionContent{
            type: :quiz_question,
            text_answer: "athena{h4ck3d}"
          }
        )

      assert Evaluator.evaluate_sync(sub_wrong).score == 0
      assert Evaluator.evaluate_sync(sub_correct).score == 100
    end

    test "grades single choice question", %{account: account, section: section} do
      opt1_id = Ecto.UUID.generate()
      opt2_id = Ecto.UUID.generate()

      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{
            "question_type" => "single",
            "options" => [
              %{"id" => opt1_id, "text" => "A", "is_correct" => false},
              %{"id" => opt2_id, "text" => "B", "is_correct" => true}
            ]
          }
        )

      submission =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          content: %SubmissionContent{
            type: :quiz_question,
            selected_choices: [opt2_id]
          }
        )

      result = Evaluator.evaluate_sync(submission)
      assert result.score == 100
    end

    test "grades multiple choice strictly", %{account: account, section: section} do
      opt1_id = Ecto.UUID.generate()
      opt2_id = Ecto.UUID.generate()
      opt3_id = Ecto.UUID.generate()

      block =
        insert(:block,
          section: section,
          type: :quiz_question,
          content: %{
            "question_type" => "multiple",
            "options" => [
              %{"id" => opt1_id, "text" => "A", "is_correct" => true},
              %{"id" => opt2_id, "text" => "B", "is_correct" => true},
              %{"id" => opt3_id, "text" => "C", "is_correct" => false}
            ]
          }
        )

      sub_partial =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          content: %SubmissionContent{
            type: :quiz_question,
            selected_choices: [opt1_id]
          }
        )

      sub_correct =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          content: %SubmissionContent{
            type: :quiz_question,
            selected_choices: [opt1_id, opt2_id]
          }
        )

      assert Evaluator.evaluate_sync(sub_partial).score == 0
      assert Evaluator.evaluate_sync(sub_correct).score == 100
    end
  end

  describe "evaluate_sync/1 for quiz_exam" do
    setup do
      section = insert(:section)
      account = insert(:account)
      block = insert(:block, section: section, type: :quiz_exam, content: %{})
      %{account: account, block: block}
    end

    test "grades exam with 100% if all answers are correct", %{account: account, block: block} do
      q1_id = Ecto.UUID.generate()
      q2_id = Ecto.UUID.generate()

      questions = [
        %{"id" => q1_id, "question_type" => "exact_match", "correct_answer" => "flag"},
        %{
          "id" => q2_id,
          "question_type" => "single",
          "options" => [
            %{"id" => "o1", "is_correct" => true},
            %{"id" => "o2", "is_correct" => false}
          ]
        }
      ]

      answers = %{q1_id => "flag", q2_id => "o1"}

      sub =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          status: :pending,
          content: %{
            "type" => "quiz_exam",
            "questions" => questions,
            "answers" => answers
          }
        )

      res = Evaluator.evaluate_sync(sub)
      assert res.score == 100
      assert res.status == :graded
    end

    test "grades exam with partial score", %{account: account, block: block} do
      q1_id = Ecto.UUID.generate()
      q2_id = Ecto.UUID.generate()

      questions = [
        %{"id" => q1_id, "question_type" => "exact_match", "correct_answer" => "flag"},
        %{
          "id" => q2_id,
          "question_type" => "single",
          "options" => [
            %{"id" => "o1", "is_correct" => true},
            %{"id" => "o2", "is_correct" => false}
          ]
        }
      ]

      answers = %{q1_id => "flag", q2_id => "o2"}

      sub =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          status: :pending,
          content: %{
            "type" => "quiz_exam",
            "questions" => questions,
            "answers" => answers
          }
        )

      res = Evaluator.evaluate_sync(sub)
      assert res.score == 50
      assert res.status == :graded
    end

    test "sets exam status to needs_review if it contains open questions", %{
      account: account,
      block: block
    } do
      q1_id = Ecto.UUID.generate()
      q2_id = Ecto.UUID.generate()

      questions = [
        %{"id" => q1_id, "question_type" => "exact_match", "correct_answer" => "flag"},
        %{"id" => q2_id, "question_type" => "open"}
      ]

      answers = %{q1_id => "flag", q2_id => "My beautiful essay"}

      sub =
        insert(:submission,
          account_id: account.id,
          block_id: block.id,
          status: :pending,
          content: %{
            "type" => "quiz_exam",
            "questions" => questions,
            "answers" => answers
          }
        )

      res = Evaluator.evaluate_sync(sub)
      assert res.score == 50

      assert res.status == :needs_review
    end
  end
end
