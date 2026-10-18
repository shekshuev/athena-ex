defmodule Athena.Surveys.QuestionTypes.Row do
  @moduledoc """
  One row (item) of a `:multi_scale` matrix question - that is, one scale item
  in a battery that all share the matrix's single scale.

  `id` lands in `SurveyAnswer.row_key`, which is part of the answer's unique
  index, so like `Option.id` it must be stable for the life of the question.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :id, :binary_id
    field :text, :string
  end

  @type t :: %__MODULE__{id: binary() | nil, text: String.t() | nil}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :text])
    |> validate_required([:id, :text])
    |> validate_length(:text, max: 500)
  end
end
