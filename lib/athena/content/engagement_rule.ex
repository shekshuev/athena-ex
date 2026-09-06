defmodule Athena.Content.EngagementRule do
  @moduledoc """
  Embedded schema defining engagement-tracking thresholds for a block or section.

  Fields are treated as overrides in a cascade (block -> section -> application
  config default, see `Athena.Content.Policy.resolve_engagement_rule/2`): a `nil`
  value means "inherit from the next level up", not "disabled".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :expected_seconds, :integer
    field :nudge_enabled, :boolean
    field :fast_ratio_threshold, :float
  end

  @doc false
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:expected_seconds, :nudge_enabled, :fast_ratio_threshold])
    |> validate_number(:expected_seconds, greater_than: 0)
    |> validate_number(:fast_ratio_threshold, greater_than: 0, less_than_or_equal_to: 1)
  end
end
