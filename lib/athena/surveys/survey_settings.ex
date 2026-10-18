defmodule Athena.Surveys.SurveySettings do
  @moduledoc """
  Presentation settings embedded in `Athena.Surveys.Survey.settings`.

  `pagination` is the one with teeth: `:all_at_once` renders every question on
  a single screen, which is incompatible with branching (a later question's
  visibility would depend on an answer the respondent can see and change
  beside it). `Athena.Surveys.Surveys` rejects `:all_at_once` for a survey
  that has branch rules, and rejects adding a rule to one set to
  `:all_at_once`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :pagination, Ecto.Enum,
      values: [:one_per_page, :by_page, :all_at_once],
      default: :one_per_page

    field :show_progress, :boolean, default: true
    field :allow_back, :boolean, default: true
    field :shuffle_questions, :boolean, default: false
  end

  @type t :: %__MODULE__{
          pagination: :one_per_page | :by_page | :all_at_once,
          show_progress: boolean(),
          allow_back: boolean(),
          shuffle_questions: boolean()
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:pagination, :show_progress, :allow_back, :shuffle_questions])
    |> validate_required([:pagination])
  end
end
