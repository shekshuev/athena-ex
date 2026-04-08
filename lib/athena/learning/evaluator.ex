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
  """
  @spec evaluate_sync(Submission.t()) :: map()
  def evaluate_sync(%Submission{status: :pending} = submission) do
    block = Repo.get!(Block, submission.block_id)

    content_type =
      Map.get(submission.content, "type") ||
        Map.get(submission.content, :type) ||
        to_string(block.type)

    if to_string(content_type) == "quiz_exam" do
      evaluate_exam(submission)
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

    %{status: status, score: score, feedback: question_data.general_explanation}
  end

  defp evaluate_exam(submission) do
    questions = get_val(submission.content, "questions", :questions, [])
    answers = get_val(submission.content, "answers", :answers, %{})

    results = Enum.map(questions, &evaluate_exam_question(&1, answers))

    calculate_exam_totals(results)
  end

  defp evaluate_exam_question(q, answers) do
    q_id = get_val(q, "id", :id)
    q_type = get_val(q, "question_type", :question_type) || get_val(q, "type", :type)

    q_attrs = %{
      "question_type" => q_type,
      "correct_answer" => get_val(q, "correct_answer", :correct_answer),
      "case_sensitive" => get_val(q, "case_sensitive", :case_sensitive, false),
      "options" => get_val(q, "options", :options, [])
    }

    q_struct =
      %QuizQuestion{}
      |> QuizQuestion.changeset(q_attrs)
      |> Ecto.Changeset.apply_changes()

    ans_val = Map.get(answers, q_id, Map.get(answers, to_string(q_id)))
    a_struct = build_answer_struct(to_string(q_type), ans_val)

    calculate_score(q_struct, a_struct)
  end

  defp get_val(map, string_key, atom_key, default \\ nil) do
    Map.get(map, string_key, Map.get(map, atom_key, default))
  end

  defp build_answer_struct("exact_match", val), do: %{type: :quiz_question, text_answer: val}
  defp build_answer_struct("open", val), do: %{type: :quiz_question, text_answer: val}

  defp build_answer_struct("single", val) when val in [nil, ""],
    do: %{type: :quiz_question, selected_choices: []}

  defp build_answer_struct("single", val), do: %{type: :quiz_question, selected_choices: [val]}

  defp build_answer_struct("multiple", val),
    do: %{type: :quiz_question, selected_choices: List.wrap(val)}

  defp build_answer_struct(_type, _val), do: %{type: :quiz_question}

  defp calculate_exam_totals([]), do: %{status: :graded, score: 0, feedback: nil}

  defp calculate_exam_totals(results) do
    total_score = results |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    avg_score = round(total_score / length(results))

    has_needs_review? = Enum.any?(results, fn {_, status} -> status == :needs_review end)
    final_status = if has_needs_review?, do: :needs_review, else: :graded

    %{status: final_status, score: avg_score, feedback: nil}
  end

  @doc false
  @spec calculate_score(QuizQuestion.t(), map()) :: {integer(), atom()}
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

    score = if match?, do: 100, else: 0

    {score, :graded}
  end

  defp calculate_score(%QuizQuestion{question_type: :single} = q, %{type: :quiz_question} = a) do
    correct_option = Enum.find(q.options || [], & &1.is_correct)
    student_choice = List.first(a.selected_choices || [])

    score = if correct_option && student_choice == correct_option.id, do: 100, else: 0

    {score, :graded}
  end

  defp calculate_score(%QuizQuestion{question_type: :multiple} = q, %{type: :quiz_question} = a) do
    correct_ids =
      q.options
      |> Enum.filter(& &1.is_correct)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    student_ids = Enum.sort(a.selected_choices || [])

    score = if correct_ids == student_ids and correct_ids != [], do: 100, else: 0

    {score, :graded}
  end

  defp calculate_score(%QuizQuestion{question_type: :open}, _a), do: {0, :needs_review}

  defp calculate_score(_q, _a), do: {0, :graded}
end
