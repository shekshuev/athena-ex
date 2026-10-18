defmodule Athena.Content.SurveyRef do
  @moduledoc """
  Embedded schema for the `content` of a `:survey` block: a reference to a
  survey, not a copy of one.

  A survey is authored once in its own builder and may appear in several
  courses; holding only its id means editing it in one place changes it
  everywhere, and the responses stay one dataset rather than one per course.

  `survey_id` is a bare id with no foreign key - `Athena.Content` and
  `Athena.Surveys` are separate contexts, and the course content tree should
  not be undeletable because a survey points into it. A block whose survey
  has been deleted renders as a notice rather than crashing the lesson.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :survey_id, :binary_id

    # Lets the same survey be introduced differently in different courses
    # without duplicating it.
    field :title_override, :string

    # Whether a student who has answered sees the aggregate afterwards.
    # Off by default: showing the running tally to later respondents is a
    # well-known way to bias them towards the majority answer.
    field :show_results_to_student, :boolean, default: false
  end

  @type t :: %__MODULE__{
          survey_id: binary() | nil,
          title_override: String.t() | nil,
          show_results_to_student: boolean()
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:survey_id, :title_override, :show_results_to_student])
    |> validate_required([:survey_id])
    |> validate_length(:title_override, max: 200)
  end
end
