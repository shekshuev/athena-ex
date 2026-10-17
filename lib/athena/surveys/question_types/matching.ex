defmodule Athena.Surveys.QuestionTypes.Matching do
  @moduledoc """
  Config for a `:matching` question - the respondent pairs each left item
  with a right item. The right-hand sides are presented shuffled.

  Unlike `Athena.Content.QuizQuestion`'s matching, nothing here is "correct":
  the pairs define the available items, and the answer records the mapping the
  respondent chose.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Surveys.QuestionTypes.Pair

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    embeds_many :pairs, Pair
  end

  @type t :: %__MODULE__{pairs: [Pair.t()]}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [])
    |> cast_embed(:pairs, with: &Pair.changeset/2)
    |> validate_min_pairs()
  end

  defp validate_min_pairs(changeset) do
    if length(get_field(changeset, :pairs) || []) < 2 do
      add_error(changeset, :pairs, "must have at least 2 pairs")
    else
      changeset
    end
  end
end
