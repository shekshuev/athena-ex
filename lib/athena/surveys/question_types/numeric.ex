defmodule Athena.Surveys.QuestionTypes.Numeric do
  @moduledoc """
  Config for a `:numeric` question - a free number (age, hours per week, count),
  optionally bounded and labelled with a `unit` shown next to the input.

  Distinct from `:scale`: there is no fixed set of points, so the answer is
  treated as a ratio-level measurement by `Athena.Surveys.Results`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :min, :float
    field :max, :float
    field :step, :float, default: 1.0
    field :unit, :string
  end

  @type t :: %__MODULE__{
          min: float() | nil,
          max: float() | nil,
          step: float(),
          unit: String.t() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:min, :max, :step, :unit])
    |> validate_number(:step, greater_than: 0)
    |> validate_length(:unit, max: 50)
    |> validate_bounds()
  end

  defp validate_bounds(changeset) do
    min = get_field(changeset, :min)
    max = get_field(changeset, :max)

    if is_number(min) and is_number(max) and min >= max do
      add_error(changeset, :max, "must be greater than the minimum")
    else
      changeset
    end
  end
end
