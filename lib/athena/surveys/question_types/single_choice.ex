defmodule Athena.Surveys.QuestionTypes.SingleChoice do
  @moduledoc """
  Config for a `:single_choice` question - pick exactly one option.

  `other_allowed` appends a write-in option; its text is stored in the
  answer's `value_text` while the choice itself is recorded as the reserved
  id `"other"`, so "how many picked something we didn't list" stays a plain
  frequency count rather than a special case.

  `randomize` shuffles the options per respondent to counter order bias (a
  write-in "other" option is always shown last regardless).
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Surveys.QuestionTypes.Option

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    embeds_many :options, Option
    field :other_allowed, :boolean, default: false
    field :randomize, :boolean, default: false
  end

  @type t :: %__MODULE__{
          options: [Option.t()],
          other_allowed: boolean(),
          randomize: boolean()
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:other_allowed, :randomize])
    |> cast_embed(:options, with: &Option.changeset/2)
    |> Athena.Surveys.QuestionTypes.validate_min_options(2)
  end
end
