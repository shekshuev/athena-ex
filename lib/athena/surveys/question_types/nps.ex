defmodule Athena.Surveys.QuestionTypes.Nps do
  @moduledoc """
  Config for an `:nps` question - the standard 0-10 recommendation scale.

  The range is fixed at 0-10 on purpose: the promoter (9-10) / passive (7-8) /
  detractor (0-6) split that `Athena.Surveys.Results` derives is only defined
  for that range, so making the bounds configurable would quietly produce a
  "NPS" that isn't one. A differently-bounded rating is a `:scale`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :min_label, :string
    field :max_label, :string
  end

  @type t :: %__MODULE__{min_label: String.t() | nil, max_label: String.t() | nil}

  @min 0
  @max 10

  @doc "The fixed lower bound of the NPS scale."
  @spec min() :: integer()
  def min, do: @min

  @doc "The fixed upper bound of the NPS scale."
  @spec max() :: integer()
  def max, do: @max

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:min_label, :max_label])
    |> validate_length(:min_label, max: 100)
    |> validate_length(:max_label, max: 100)
  end
end
