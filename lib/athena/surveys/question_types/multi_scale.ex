defmodule Athena.Surveys.QuestionTypes.MultiScale do
  @moduledoc """
  Config for a `:multi_scale` question - a matrix (grid) of `rows`, all rated
  on one shared scale. Sociologically this is a battery of scale items, and
  it is stored as one, not as a single composite answer: a `:multi_scale`
  question writes **one `SurveyAnswer` row per matrix row**, keyed by
  `row_key`.

  That storage choice is what makes Cronbach's alpha, item-total correlations
  and per-item descriptives plain SQL over `value_numeric` instead of JSON
  surgery over a nested map.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Surveys.QuestionTypes.{Row, ScaleBounds}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    embeds_many :rows, Row
    field :min, :integer, default: 1
    field :max, :integer, default: 5
    field :step, :integer, default: 1
    field :min_label, :string
    field :max_label, :string
    field :point_labels, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{
          rows: [Row.t()],
          min: integer(),
          max: integer(),
          step: integer(),
          min_label: String.t() | nil,
          max_label: String.t() | nil,
          point_labels: [String.t()]
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:min, :max, :step, :min_label, :max_label, :point_labels])
    |> cast_embed(:rows, with: &Row.changeset/2)
    |> validate_required([:min, :max, :step])
    |> validate_min_rows()
    |> ScaleBounds.validate()
  end

  defp validate_min_rows(changeset) do
    if length(get_field(changeset, :rows) || []) < 1 do
      add_error(changeset, :rows, "must have at least 1 row")
    else
      changeset
    end
  end
end
