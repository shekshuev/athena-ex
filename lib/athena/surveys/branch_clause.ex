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
    field :id, :binary_id
    field :question_id, :binary_id
    field :op, Ecto.Enum, values: @operators
    field :value, :map, default: %{}
  end

  @type t :: %__MODULE__{
          id: binary() | nil,
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

  @doc """
  The operators worth offering for a question of this measurement level.

  Narrower than `operators/0` on purpose: `Athena.Surveys.Flow` treats an
  operand that does not fit the answer as false, so offering `:gt` on a
  free-text question would only let an author build a rule that can never
  match. The engine stays permissive; the editor stays honest.
  """
  @spec operators_for(Athena.Surveys.QuestionTypes.measurement()) :: [atom()]
  def operators_for(:interval), do: ~w(eq neq gt gte lt lte between answered not_answered)a
  def operators_for(:ratio), do: operators_for(:interval)

  def operators_for(:nominal),
    do: ~w(eq neq in not_in contains_any contains_all answered not_answered)a

  def operators_for(:ordinal), do: ~w(contains_any contains_all answered not_answered)a
  def operators_for(:text), do: ~w(eq neq in not_in answered not_answered)a

  @doc """
  What kind of operand an operator needs for a question of this measurement
  level. The editor renders the matching input, and resets a stored operand
  when the kind changes - an operand left over from a different kind would be
  read as a malformed one and the rule would silently never match.
  """
  @spec operand_kind(atom(), Athena.Surveys.QuestionTypes.measurement()) ::
          :none | :number | :range | :choices | :texts | :text
  def operand_kind(op, _measurement) when op in @nullary, do: :none
  def operand_kind(:between, _measurement), do: :range
  def operand_kind(op, :text) when op in [:in, :not_in], do: :texts
  def operand_kind(_op, :text), do: :text
  def operand_kind(_op, measurement) when measurement in [:interval, :ratio], do: :number
  def operand_kind(_op, _measurement), do: :choices

  @doc """
  A new clause, with an id. The id lets the logic editor address one clause of
  a rule without relying on its position in the list - the same reason the
  question editor addresses options by id: a position that shifts while
  someone is typing in a sibling no longer means what it meant when it was
  rendered.
  """
  @spec new(map()) :: map()
  def new(attrs \\ %{}) do
    Map.merge(%{"id" => Ecto.UUID.generate(), "op" => "answered", "value" => %{}}, attrs)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :question_id, :op, :value])
    |> ensure_id()
    |> validate_required([:id, :question_id, :op])
    |> validate_value_present()
  end

  # A clause stored before ids existed, or posted without one, still has to
  # validate rather than fail on a field the author never saw.
  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, Ecto.UUID.generate())
      _ -> changeset
    end
  end

  # An operator that takes no operand has its operand cleared, so a leftover
  # value cannot be read later as if it meant something.
  #
  # A *missing* operand is deliberately not an error. An author switching the
  # operator has not yet typed the new value, and refusing the save would mean
  # the operator could never be changed at all - the form would bounce back
  # every time. `Athena.Surveys.Flow` treats a missing operand as false and
  # `validate_graph/1` reports it as `:clause_without_operand`, which is the
  # same bargain the rest of the logic model makes: report, do not refuse.
  defp validate_value_present(changeset) do
    case get_field(changeset, :op) do
      nil -> changeset
      op when op in @nullary -> put_change(changeset, :value, %{})
      _op -> changeset
    end
  end

  @doc """
  Whether a clause has the operand its operator needs - that is, whether it
  can ever match. Used by `Athena.Surveys.Flow.validate_graph/1`.
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{op: op}) when op in @nullary, do: true
  def complete?(%__MODULE__{value: value}) when is_map(value), do: map_size(value) > 0
  def complete?(%__MODULE__{}), do: false
end
