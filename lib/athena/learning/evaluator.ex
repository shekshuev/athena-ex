defmodule Athena.Learning.Evaluator do
  @moduledoc """
  Synchronous evaluator for auto-graded submissions.
  Handles exact match, single, multiple choice, and orchestrates Exam rollups.
  """

  alias Athena.Learning.{Submission, Submissions}
  alias Athena.Content.{Block, QuizQuestion}
  alias Athena.Repo

  @doc """
  Evaluates a pending submission synchronously.

  Loads the associated block, compares the student's submission content
  against the block's question definition, and calculates a score (0-100).
  """
  @spec evaluate_sync(Submission.t()) :: map()
  def evaluate_sync(%Submission{status: :pending} = submission) do
    block = Repo.get!(Block, submission.block_id)

    content_type =
      Map.get(submission.content, "type") ||
        Map.get(submission.content, :type) ||
        to_string(block.type)

    if to_string(content_type) == "quiz_exam" do
      evaluate_exam(submission, block)
    else
      evaluate_single_question(block, submission)
    end
  end

  def evaluate_sync(_submission), do: %{}

  defp evaluate_single_question(block, submission) do
    question_data =
      %QuizQuestion{}
      |> QuizQuestion.changeset(block.content)
      |> Ecto.Changeset.apply_changes()

    {score, status} = calculate_score(question_data, submission.content)

    %{status: status, score: score}
  end

  @doc false
  defp evaluate_exam(parent_submission, _exam_block) do
    child_subs = Submissions.get_child_submissions(parent_submission.id)
    questions = parent_submission.content["questions"] || []
    total_questions = length(questions)

    results =
      Enum.map(questions, fn q ->
        child_sub = Map.get(child_subs, q["id"])
        block_type = to_string(q["type"] || "quiz_question")
        q_content = q["content"] || %{}

        cond do
          is_nil(child_sub) ->
            is_manual =
              block_type in ["code", "file_assignment"] or q_content["question_type"] == "open"

            blank_content =
              case block_type do
                "code" -> %{"type" => "code", "code" => ""}
                "file_assignment" -> %{"type" => "file_assignment", "file_urls" => []}
                _ -> %{"type" => "quiz_question", "text_answer" => ""}
              end

            {:ok, new_sub} =
              Submissions.save_question_submission(
                parent_submission,
                parent_submission.account_id,
                q["id"],
                parent_submission.cohort_id,
                blank_content
              )

            if is_manual do
              {:ok, _} =
                Submissions.system_update_submission(new_sub, %{score: nil, status: :needs_review})

              {nil, :needs_review}
            else
              {:ok, _} =
                Submissions.system_update_submission(new_sub, %{score: 0, status: :graded})

              {0, :graded}
            end

          child_sub.status in [:needs_review, :graded, :rejected] ->
            {child_sub.score || 0, child_sub.status}

          block_type == "code" ->
            {:ok, _} = Submissions.enqueue_code_execution(child_sub)
            {nil, :processing}

          block_type == "file_assignment" ->
            {:ok, _} =
              Submissions.system_update_submission(child_sub, %{score: nil, status: :needs_review})

            {nil, :needs_review}

          true ->
            question_data =
              %QuizQuestion{}
              |> QuizQuestion.changeset(q_content)
              |> Ecto.Changeset.apply_changes()

            {score, status} = calculate_score(question_data, child_sub.content)

            {:ok, _} =
              Submissions.system_update_submission(child_sub, %{score: score, status: status})

            {score, status}
        end
      end)

    calculate_exam_totals(results, total_questions)
  end

  defp calculate_exam_totals([], _), do: %{status: :graded, score: 0, feedback: nil}

  defp calculate_exam_totals(results, total_questions) do
    total_earned =
      results
      |> Enum.map(fn {score, _status} -> score || 0 end)
      |> Enum.sum()

    avg_score = if total_questions > 0, do: round(total_earned / total_questions), else: 0

    has_needs_review? = Enum.any?(results, fn {_, status} -> status == :needs_review end)
    final_status = if has_needs_review?, do: :needs_review, else: :graded

    %{status: final_status, score: avg_score, feedback: nil}
  end

  defp calculate_score(%QuizQuestion{question_type: :exact_match} = q, a) do
    correct = q.correct_answer || ""
    student = Map.get(a, "text_answer") || ""

    match? =
      if q.case_sensitive do
        String.trim(student) == String.trim(correct)
      else
        String.downcase(String.trim(student)) == String.downcase(String.trim(correct))
      end

    if match?, do: {100, :graded}, else: {0, :graded}
  end

  defp calculate_score(%QuizQuestion{question_type: :single} = q, a) do
    correct_option = Enum.find(q.options || [], & &1.is_correct)
    student_choice = List.first(Map.get(a, "selected_choices") || [])

    if correct_option && student_choice == correct_option.id,
      do: {100, :graded},
      else: {0, :graded}
  end

  defp calculate_score(%QuizQuestion{question_type: :multiple} = q, a) do
    correct_ids = q.options |> Enum.filter(& &1.is_correct) |> Enum.map(& &1.id) |> Enum.sort()
    student_ids = Enum.sort(Map.get(a, "selected_choices") || [])

    if correct_ids == student_ids and correct_ids != [], do: {100, :graded}, else: {0, :graded}
  end

  defp calculate_score(%QuizQuestion{question_type: :open}, _), do: {nil, :needs_review}

  defp calculate_score(_q, _a), do: {0, :graded}
end
