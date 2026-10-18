defmodule Athena.Surveys.QuestionTypes.Pair do
  @moduledoc """
  One left/right pair of a `:matching` question. Mirrors the shape of
  `Athena.Content.QuizQuestion.Pair`, but with plain-text sides and no notion
  of a correct answer - a survey records what the respondent matched, it does
  not mark it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :id, :binary_id
    field :left, :string
    field :right, :string
  end

  @type t :: %__MODULE__{
          id: binary() | nil,
          left: String.t() | nil,
          right: String.t() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :left, :right])
    |> validate_required([:id, :left, :right])
  end
end
