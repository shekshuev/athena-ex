defmodule Athena.Surveys.SurveyBranch do
  @moduledoc """
  One branching rule: after `question_id` is answered, if `condition` holds,
  do `action`.

  Rules are rows rather than embeds in the survey so the logic editor can
  reorder and validate them one at a time, and so `Athena.Surveys.Flow` can
  load only the rules for the question it is currently evaluating.

  `position` breaks ties: the rules for a question are evaluated in order and
  **the first match wins**, so an author orders specific rules above general
  ones. Like `SurveyQuestion.position` it is not uniquely indexed.

  A rule's clauses may only reference questions that come *before* the owning
  question, and `action` targets may only point *forward*. Both are checked by
  `Athena.Surveys.Flow.validate_graph/1` rather than here, because they are
  properties of the whole survey, not of one row: a rule that is valid on its
  own can still create a cycle.

  `condition` holds the embedded `BranchCondition` as jsonb - the *structure*
  is embedded, the *rules* are rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Surveys.{BranchCondition, Survey, SurveyQuestion}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @actions [:goto_question, :goto_page, :end_survey, :skip_question]

  schema "survey_branches" do
    field :position, :integer, default: 0
    field :action, Ecto.Enum, values: @actions
    field :target_question_id, :binary_id
    field :target_page, :integer

    embeds_one :condition, BranchCondition, on_replace: :update

    belongs_to :survey, Survey
    belongs_to :question, SurveyQuestion

    timestamps(type: :utc_datetime)
  end

  @doc "Every supported branch action."
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(branch, attrs) do
    branch
    |> cast(attrs, [
      :position,
      :action,
      :target_question_id,
      :target_page,
      :survey_id,
      :question_id
    ])
    |> cast_embed(:condition, with: &BranchCondition.changeset/2, required: true)
    |> validate_required([:action, :survey_id, :question_id])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_target()
    |> foreign_key_constraint(:survey_id)
    |> foreign_key_constraint(:question_id)
  end

  # Each action needs exactly its own target, and the others are cleared - an
  # orphan `target_page` left behind by switching the action would otherwise
  # be read by nothing and confuse the next person to open the rule.
  defp validate_target(changeset) do
    case get_field(changeset, :action) do
      :goto_question ->
        changeset
        |> validate_required([:target_question_id])
        |> put_change(:target_page, nil)

      :goto_page ->
        changeset
        |> validate_required([:target_page])
        |> validate_number(:target_page, greater_than_or_equal_to: 0)
        |> put_change(:target_question_id, nil)

      action when action in [:end_survey, :skip_question] ->
        changeset
        |> put_change(:target_question_id, nil)
        |> put_change(:target_page, nil)

      nil ->
        changeset
    end
  end
end
