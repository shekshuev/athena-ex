defmodule Athena.Surveys.Responses do
  @moduledoc """
  Internal business logic for taking a survey: starting or resuming a
  response, autosaving answers, advancing, and finishing.

  ## Attribution

  `resolve_cohort/2` is the only place that decides whether a response is
  attributed to a cohort, and it is always called server-side from the
  student's own session - the cohort is never accepted from the client, or a
  student could choose which group their feedback counted towards.

  A `nil` cohort means individual enrollment, and that is what tells the
  results layer it may show who answered. See
  `Athena.Surveys.SurveyResponse` for the full rule.

  ## Autosave

  `save_answer/4` upserts on `(response_id, question_id, row_key)`, so a
  respondent changing their mind replaces a row rather than adding one, and a
  survey abandoned halfway is simply an `:in_progress` response with the
  answers given so far - which is what makes partial responses visible to the
  instructor at no extra cost.
  """

  import Ecto.Query

  alias Athena.Learning
  alias Athena.Repo
  alias Athena.Surveys.{QuestionTypes, Survey, SurveyAnswer, SurveyQuestion, SurveyResponse}

  @replaceable [
    :value,
    :value_numeric,
    :value_text,
    :value_choice_ids,
    :skipped,
    :answered_at,
    :updated_at
  ]

  @doc """
  Resolves the cohort a response should be attributed to.

  A survey answered inside a course uses the cohort the student is enrolled
  through; `nil` when they are enrolled individually. A standalone survey has
  no course to resolve against and so attributes to the account until
  `survey_targets` exists.
  """
  @spec resolve_cohort(binary(), binary() | nil) :: binary() | nil
  def resolve_cohort(_account_id, nil), do: nil

  def resolve_cohort(account_id, course_id) do
    case Learning.get_user_cohort_for_course(account_id, course_id) do
      nil -> nil
      cohort -> cohort.id
    end
  end

  @doc """
  Returns this student's response to a survey, whatever its state, or `nil`.

  This is the resume lookup: the unique index on `(survey_id, account_id)`
  means there is at most one.
  """
  @spec get_response(binary(), binary()) :: SurveyResponse.t() | nil
  def get_response(survey_id, account_id) do
    Repo.get_by(SurveyResponse, survey_id: survey_id, account_id: account_id)
  end

  @doc """
  Starts a response, or returns the one already in progress.

  `context` carries `:course_id` and `:block_id` when the survey is being
  answered inside a course, and is empty for a standalone run.

  Returns `{:already_completed, response}` when the student has finished the
  survey - the caller shows "you have already answered this" rather than
  quietly creating a second response (which the unique index would refuse
  anyway).
  """
  @spec get_or_start(Survey.t(), map(), map()) ::
          {:ok, SurveyResponse.t()}
          | {:already_completed, SurveyResponse.t()}
          | {:error, :not_open | Ecto.Changeset.t()}
  def get_or_start(%Survey{} = survey, user, context \\ %{}) do
    case get_response(survey.id, user.id) do
      %SurveyResponse{status: :completed} = response ->
        {:already_completed, response}

      %SurveyResponse{} = response ->
        {:ok, response}

      nil ->
        start(survey, user, context)
    end
  end

  defp start(%Survey{status: :published} = survey, user, context) do
    course_id = Map.get(context, :course_id)

    %SurveyResponse{}
    |> SurveyResponse.create_changeset(%{
      survey_id: survey.id,
      account_id: user.id,
      cohort_id: resolve_cohort(user.id, course_id),
      course_id: course_id,
      block_id: Map.get(context, :block_id)
    })
    |> Repo.insert()
  end

  # A draft, closed or archived survey is not answerable. Checked here rather
  # than only in the UI, since a block can keep pointing at a survey that was
  # closed after the course was published.
  defp start(%Survey{}, _user, _context), do: {:error, :not_open}

  @doc """
  Saves one answer, replacing any previous answer to the same question (and
  matrix row).

  `question` is passed as a struct, not an id, because the answer's typed
  projections are derived from its `type` - see
  `Athena.Surveys.SurveyAnswer`.
  """
  @spec save_answer(SurveyResponse.t(), SurveyQuestion.t(), map(), keyword()) ::
          {:ok, SurveyAnswer.t()} | {:error, Ecto.Changeset.t()}
  def save_answer(%SurveyResponse{} = response, %SurveyQuestion{} = question, value, opts \\ []) do
    attrs = %{
      response_id: response.id,
      question_id: question.id,
      value: value,
      skipped: Keyword.get(opts, :skipped, false)
    }

    %SurveyAnswer{}
    |> SurveyAnswer.changeset(attrs, question.type)
    |> Repo.insert(
      on_conflict: {:replace, @replaceable},
      conflict_target: [:response_id, :question_id, :row_key]
    )
  end

  @doc """
  Records that a question was deliberately left blank.

  A skip is stored, not inferred from a missing row: "20 people saw this
  question and declined to answer" is a different finding from "20 people
  never got there", and only an explicit row can tell them apart.
  """
  @spec skip_answer(SurveyResponse.t(), SurveyQuestion.t(), map()) ::
          {:ok, SurveyAnswer.t()} | {:error, Ecto.Changeset.t()}
  def skip_answer(%SurveyResponse{} = response, %SurveyQuestion{} = question, value \\ %{}) do
    save_answer(response, question, value, skipped: true)
  end

  @doc "Lists a response's answers."
  @spec list_answers(binary()) :: [SurveyAnswer.t()]
  def list_answers(response_id) do
    SurveyAnswer
    |> where([a], a.response_id == ^response_id)
    |> Repo.all()
  end

  @doc """
  A response's answers keyed by `{question_id, row_key}` - the shape the
  player holds in its socket assigns and the flow engine evaluates conditions
  against.
  """
  @spec answers_map(binary()) :: %{{binary(), String.t()} => SurveyAnswer.t()}
  def answers_map(response_id) do
    response_id
    |> list_answers()
    |> Map.new(&{{&1.question_id, &1.row_key}, &1})
  end

  @doc "Moves the resume point to `question_id`."
  @spec advance(SurveyResponse.t(), binary() | nil) ::
          {:ok, SurveyResponse.t()} | {:error, Ecto.Changeset.t()}
  def advance(%SurveyResponse{} = response, question_id) do
    response
    |> SurveyResponse.progress_changeset(%{current_question_id: question_id})
    |> Repo.update()
  end

  @doc "Marks a response finished."
  @spec complete(SurveyResponse.t()) ::
          {:ok, SurveyResponse.t()} | {:error, Ecto.Changeset.t()}
  def complete(%SurveyResponse{} = response) do
    response
    |> SurveyResponse.progress_changeset(%{status: :completed})
    |> Repo.update()
  end

  @doc """
  Marks a stale in-progress response abandoned. Its answers are kept - that
  partial data is the point.
  """
  @spec abandon(SurveyResponse.t()) ::
          {:ok, SurveyResponse.t()} | {:error, Ecto.Changeset.t()}
  def abandon(%SurveyResponse{} = response) do
    response
    |> SurveyResponse.progress_changeset(%{status: :abandoned})
    |> Repo.update()
  end

  @doc """
  Deletes a student's response so they can answer again - the instructor's
  "let them retake it" action.

  Destructive, and named to say so: the previous answers are gone, which is
  why nothing calls it as part of the normal flow.
  """
  @spec reset_response(SurveyResponse.t()) ::
          {:ok, SurveyResponse.t()} | {:error, Ecto.Changeset.t()}
  def reset_response(%SurveyResponse{} = response), do: Repo.delete(response)

  @doc "Lists a survey's responses, newest first, optionally filtered by status."
  @spec list_responses(binary(), keyword()) :: [SurveyResponse.t()]
  def list_responses(survey_id, opts \\ []) do
    SurveyResponse
    |> where([r], r.survey_id == ^survey_id)
    |> filter_status(Keyword.get(opts, :status))
    |> filter_cohort(Keyword.get(opts, :cohort_id))
    |> order_by([r], desc: r.started_at)
    |> Repo.all()
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, [r], r.status == ^status)

  defp filter_cohort(query, nil), do: query
  defp filter_cohort(query, cohort_id), do: where(query, [r], r.cohort_id == ^cohort_id)

  @doc """
  Counts a survey's responses by status, including statuses with no rows so
  callers can render a complete breakdown without filling gaps themselves.
  """
  @spec count_by_status(binary()) :: %{atom() => non_neg_integer()}
  def count_by_status(survey_id) do
    counts =
      SurveyResponse
      |> where([r], r.survey_id == ^survey_id)
      |> group_by([r], r.status)
      |> select([r], {r.status, count(r.id)})
      |> Repo.all()
      |> Map.new()

    Map.merge(%{in_progress: 0, completed: 0, abandoned: 0}, counts)
  end

  @doc """
  Whether this type of question stores one answer row per sub-item, which the
  player needs in order to save a matrix row by row.
  """
  @spec multi_row?(QuestionTypes.t()) :: boolean()
  def multi_row?(type), do: QuestionTypes.multi_row?(type)
end
