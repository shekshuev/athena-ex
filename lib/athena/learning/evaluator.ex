defmodule Athena.Learning.Evaluator do
  @moduledoc """
  Synchronous evaluator for auto-graded submissions.

  Handles grading for exact match (CTF flags), single choice,
  and multiple choice questions. Updates the submission with
  the calculated score and feedback.
  """

  alias Athena.Learning.Submission
  alias Athena.Content.{Block, QuizQuestion}
  alias Athena.Repo

  @doc """
  Evaluates a pending submission synchronously.

  Loads the associated block, compares the student's submission content
  against the block's question definition, and calculates a score (0-100).

  Returns a map of attributes `%{status: :graded, score: integer(), feedback: string()}`
  to update the submission with. Returns an empty map if the submission is not pending.
  """
  @spec evaluate_sync(Submission.t()) :: map()
  def evaluate_sync(%Submission{status: :pending} = submission) do
    block = Repo.get!(Block, submission.block_id)

    question_data =
      %QuizQuestion{}
      |> QuizQuestion.changeset(block.content)
      |> Ecto.Changeset.apply_changes()

    answer_data = submission.content

    score = calculate_score(question_data, answer_data)

    %{
      status: :graded,
      score: score,
      feedback: question_data.general_explanation
    }
  end

  def evaluate_sync(_submission), do: %{}

  @doc false
  @spec calculate_score(QuizQuestion.t(), map()) :: integer()
  defp calculate_score(
         %QuizQuestion{question_type: :exact_match} = q,
         %{type: :quiz_question} = a
       ) do
    correct = q.correct_answer || ""
    student = a.text_answer || ""

    match? =
      if q.case_sensitive do
        String.trim(student) == String.trim(correct)
      else
        String.downcase(String.trim(student)) == String.downcase(String.trim(correct))
      end

    if match?, do: 100, else: 0
  end

  defp calculate_score(%QuizQuestion{question_type: :single} = q, %{type: :quiz_question} = a) do
    correct_option = Enum.find(q.options || [], & &1.is_correct)
    student_choice = List.first(a.selected_choices || [])

    if correct_option && student_choice == correct_option.id, do: 100, else: 0
  end

  defp calculate_score(%QuizQuestion{question_type: :multiple} = q, %{type: :quiz_question} = a) do
    correct_ids =
      q.options
      |> Enum.filter(& &1.is_correct)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    student_ids = Enum.sort(a.selected_choices || [])

    if correct_ids == student_ids and correct_ids != [], do: 100, else: 0
  end

  defp calculate_score(%QuizQuestion{question_type: :open}, _a), do: 0

  defp calculate_score(_q, _a), do: 0
end
