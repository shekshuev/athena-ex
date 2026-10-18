defmodule Athena.Surveys.QuestionTypes.Dichotomous do
  @moduledoc """
  Config for a `:dichotomous` question - a labelled yes/no.

  Deliberately not a two-option `:single_choice`: the answer also projects to
  `value_numeric` as 1.0/0.0, so a battery of yes/no items averages directly
  into proportions and correlates with scale items without a recode step.
  The stored choice ids are the reserved strings `"yes"` and `"no"`, so
  relabelling the question later does not invalidate answers already given.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :yes_label, :string, default: "Yes"
    field :no_label, :string, default: "No"
  end

  @type t :: %__MODULE__{yes_label: String.t(), no_label: String.t()}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:yes_label, :no_label])
    |> validate_required([:yes_label, :no_label])
    |> validate_length(:yes_label, max: 100)
    |> validate_length(:no_label, max: 100)
  end
end
