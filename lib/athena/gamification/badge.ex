defmodule Athena.Gamification.Badge do
  @moduledoc """
  Admin-authored badge catalog entry.

  `rule` is a mini rule-DSL tree evaluated by `Athena.Gamification.RuleEngine`
  against `Athena.Gamification.Facts`:

      # leaf: {"fact" => name, "op" => "gte"|"lte"|"gt"|"lt"|"eq"|"ne", "value" => n, "args" => %{}}
      # combinators: {"and" => [rule, ...]} | {"or" => [rule, ...]} | {"not" => rule}

  e.g. "10 accepted SQL submissions and a 3-week streak":

      %{"and" => [
        %{"fact" => "accepted_submissions_count", "args" => %{"block_type" => "code"}, "op" => "gte", "value" => 10},
        %{"fact" => "streak_weeks", "op" => "gte", "value" => 3}
      ]}
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Athena.Gamification.RuleEngine

  @type t :: %__MODULE__{}

  @scopes ~w(global course cohort)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_badges" do
    field :key, :string
    field :title, :string
    field :description, :string
    field :icon, :string, default: "hero-star"
    field :rule, :map
    field :scope, Ecto.Enum, values: @scopes, default: :global
    field :scope_id, :binary_id
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or editing a badge. Validates `rule`
  structurally (known facts/operators, well-formed nesting) so an admin
  gets feedback before saving a badge that could never trigger.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(badge, attrs) do
    badge
    |> cast(attrs, [:key, :title, :description, :icon, :rule, :scope, :scope_id, :is_active])
    |> validate_required([:key, :title, :rule])
    |> validate_format(:key, ~r/^[a-z0-9_\-]+$/,
      message: "must be lowercase letters, numbers, dashes, or underscores"
    )
    |> validate_rule()
    |> unique_constraint(:key)
  end

  defp validate_rule(changeset) do
    case get_change(changeset, :rule) do
      nil ->
        changeset

      rule ->
        case RuleEngine.validate(rule) do
          :ok -> changeset
          {:error, reason} -> add_error(changeset, :rule, reason)
        end
    end
  end
end
