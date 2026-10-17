defmodule Athena.Surveys.BranchClause do
  @moduledoc """
  One test inside a `Athena.Surveys.BranchCondition` - "question X, operator,
  value".

  `value` is a map rather than a scalar so one shape covers every operator:
  `%{"choice_ids" => [...]}` for the membership operators, `%{"number" => n}`
  for the comparisons, `%{"from" => a, "to" => b}` for `:between`, and an
  empty map for `:answered`/`:not_answered`, which test only presence.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @operators ~w(eq neq in not_in gt gte lt lte between answered not_answered
                contains_any contains_all)a

  # Operators that need no operand at all.
  @nullary ~w(answered not_answered)a

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :question_id, :binary_id
    field :op, Ecto.Enum, values: @operators
    field :value, :map, default: %{}
  end

  @type t :: %__MODULE__{
          question_id: binary() | nil,
          op: atom() | nil,
          value: map()
        }

  @doc "Every supported operator."
  @spec operators() :: [atom()]
  def operators, do: @operators

  @doc "Operators that take no operand."
  @spec nullary_operators() :: [atom()]
  def nullary_operators, do: @nullary

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:question_id, :op, :value])
    |> validate_required([:question_id, :op])
    |> validate_value_present()
  end

  defp validate_value_present(changeset) do
    op = get_field(changeset, :op)
    value = get_field(changeset, :value) || %{}

    cond do
      is_nil(op) -> changeset
      op in @nullary -> put_change(changeset, :value, %{})
      map_size(value) > 0 -> changeset
      true -> add_error(changeset, :value, "is required for the #{op} operator")
    end
  end
end
