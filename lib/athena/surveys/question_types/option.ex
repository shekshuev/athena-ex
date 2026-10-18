defmodule Athena.Surveys.QuestionTypes.Option do
  @moduledoc """
  One selectable answer option, used by the choice-shaped question types
  (`:single_choice`, `:multiple_choice`, `:ranking`).

  `id` is a stable binary id generated when the option is first added in the
  builder, and it is never regenerated: branching conditions reference it, and
  `SurveyAnswer.value_choice_ids` stores it, so a regenerated id would silently
  break every existing rule and orphan every answer already collected.

  `text` is plain text, not a TipTap document (unlike a question's `body`) -
  option labels are axis labels and crosstab headers, and they have to survive
  a trip into a CSV cell.
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
