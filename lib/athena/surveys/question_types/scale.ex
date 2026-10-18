defmodule Athena.Surveys.QuestionTypes.Scale do
  @moduledoc """
  Config for a `:scale` question - a single Likert-style rating.

  `min_label`/`max_label` label the poles; `point_labels`, when non-empty,
  labels every point and must have exactly one entry per point (enforced by
  `Athena.Surveys.QuestionTypes.ScaleBounds`). The answer projects to
  `value_numeric`, so a scale is what `Results.descriptives/3` and the
  correlation matrix operate on.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Surveys.QuestionTypes.ScaleBounds

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :min, :integer, default: 1
    field :max, :integer, default: 5
    field :step, :integer, default: 1
    field :min_label, :string
    field :max_label, :string
    field :point_labels, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{
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
    |> validate_required([:min, :max, :step])
    |> ScaleBounds.validate()
  end
end
