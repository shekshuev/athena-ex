defmodule Athena.Surveys.QuestionTypes.MultipleChoice do
  @moduledoc """
  Config for a `:multiple_choice` question - pick any number of options,
  optionally bounded by `min_select`/`max_select` (both `nil` = unbounded).

  See `Athena.Surveys.QuestionTypes.SingleChoice` for `other_allowed` and
  `randomize`, which behave identically here.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Surveys.QuestionTypes
  alias Athena.Surveys.QuestionTypes.Option

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    embeds_many :options, Option
    field :other_allowed, :boolean, default: false
    field :randomize, :boolean, default: false
    field :min_select, :integer
    field :max_select, :integer
  end

  @type t :: %__MODULE__{
          options: [Option.t()],
          other_allowed: boolean(),
          randomize: boolean(),
          min_select: integer() | nil,
          max_select: integer() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:other_allowed, :randomize, :min_select, :max_select])
    |> cast_embed(:options, with: &Option.changeset/2)
    |> QuestionTypes.validate_min_options(2)
    |> validate_number(:min_select, greater_than: 0)
    |> validate_number(:max_select, greater_than: 0)
    |> validate_select_range()
  end

  defp validate_select_range(changeset) do
    min = get_field(changeset, :min_select)
    max = get_field(changeset, :max_select)

    if is_integer(min) and is_integer(max) and min > max do
      add_error(changeset, :max_select, "must be at least the minimum")
    else
      changeset
    end
  end
end
