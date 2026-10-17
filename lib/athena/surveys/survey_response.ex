defmodule Athena.Surveys.SurveyResponse do
  @moduledoc """
  One student's run through a survey, created the moment they start rather
  than when they finish.

  That is deliberate: answers are upserted as they are given, so an
  unfinished survey is simply an `:in_progress` response with some answers
  attached, and every results query already reads it. The instructor sees a
  partial response for free, which is the whole point - abandonment *is* the
  feedback on a question that is too long or too personal.

  ## Attribution and what the UI may show

  `account_id` is always set. `cohort_id` records the cohort the student is
  enrolled through, resolved server-side at creation from
  `Athena.Learning.Enrollments.get_user_cohort_for_course/2` - never passed in
  from the client.

  `cohort_id` therefore doubles as the display rule:

    * set    -> the student reached the survey through a cohort, so results
                group by cohort and **the UI and exports must not reveal who
                answered**. `Athena.Surveys.Results.respondent_label/2` is the
                single place that decides this.
    * `nil`  -> individual enrollment. There is no group to aggregate into, so
                the response is shown against the student.

  This is privacy at the presentation layer, not anonymity: anyone with SQL
  access can see `account_id`. That is an accepted, deliberate trade - it buys
  resumability, one-response-per-student and partial visibility with no extra
  machinery.

  The unique index on `(survey_id, account_id)` does double duty: it stops a
  student answering twice, and it is how an interrupted response is found
  again on the next page load.

  `course_id`/`block_id` are provenance for a survey answered inside a course,
  and `nil` for a standalone one. Bare ids, no foreign keys, per this
  codebase's cross-context convention.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Surveys.{Survey, SurveyAnswer}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {
    Flop.Schema,
    filterable: [:status, :cohort_id],
    sortable: [:started_at, :completed_at],
    default_limit: 50,
    default_order: %{
      order_by: [:started_at],
      order_directions: [:desc]
    }
  }

  schema "survey_responses" do
    field :account_id, :binary_id
    field :cohort_id, :binary_id

    field :status, Ecto.Enum,
      values: [:in_progress, :completed, :abandoned],
      default: :in_progress

    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :last_activity_at, :utc_datetime
    field :course_id, :binary_id
    field :block_id, :binary_id
    field :current_question_id, :binary_id

    belongs_to :survey, Survey

    has_many :answers, SurveyAnswer, foreign_key: :response_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a response. `account_id` and the attribution are set
  by `Athena.Surveys.Responses`, not by anything reading user input.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(response, attrs) do
    response
    |> cast(attrs, [
      :survey_id,
      :account_id,
      :cohort_id,
      :course_id,
      :block_id,
      :current_question_id
    ])
    |> validate_required([:survey_id, :account_id])
    |> put_change(:status, :in_progress)
    |> put_timestamps()
    |> foreign_key_constraint(:survey_id)
    |> unique_constraint([:survey_id, :account_id],
      name: :survey_responses__survey_id__account_id__uk,
      message: "has already been answered by this student"
    )
  end

  @doc """
  Changeset for advancing or finishing a response. `account_id`, `cohort_id`
  and `survey_id` are not castable here - attribution is decided once, at
  creation, and must not be rewritten by a later save.
  """
  @spec progress_changeset(t(), map()) :: Ecto.Changeset.t()
  def progress_changeset(response, attrs) do
    response
    |> cast(attrs, [:status, :current_question_id])
    |> put_change(:last_activity_at, now())
    |> maybe_put_completed_at()
  end

  defp maybe_put_completed_at(changeset) do
    case get_field(changeset, :status) do
      :completed ->
        # Preserve the first completion if a completed response is saved again.
        case get_field(changeset, :completed_at) do
          nil -> put_change(changeset, :completed_at, now())
          _ -> changeset
        end

      _ ->
        changeset
    end
  end

  defp put_timestamps(changeset) do
    now = now()

    changeset
    |> put_change(:started_at, now)
    |> put_change(:last_activity_at, now)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
