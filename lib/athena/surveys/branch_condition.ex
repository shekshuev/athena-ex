defmodule Athena.Surveys.BranchCondition do
  @moduledoc """
  The condition of a branch rule: a list of `Athena.Surveys.BranchClause`
  combined with `:and` or `:or`.

  One level of nesting only - no arbitrary boolean trees. A respondent-facing
  survey whose logic needs more than "all of these" or "any of these" is
  almost always better expressed as two rules, and a rule list the author can
  read top to bottom is worth more than expressive power nobody can review.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Surveys.BranchClause

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :logic, Ecto.Enum, values: [:and, :or], default: :and
    embeds_many :clauses, BranchClause
  end

  @type t :: %__MODULE__{logic: :and | :or, clauses: [BranchClause.t()]}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:logic])
    |> cast_embed(:clauses, with: &BranchClause.changeset/2)
    |> validate_required([:logic])
    |> validate_min_clauses()
  end

  defp validate_min_clauses(changeset) do
    if length(get_field(changeset, :clauses) || []) < 1 do
      add_error(changeset, :clauses, "must have at least 1 clause")
    else
      changeset
    end
  end
end
