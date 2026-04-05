defmodule Athena.Content.QuizExam do
  @moduledoc """
  Embedded schema for the `content` field of a `:quiz_exam` block.
  Stores the configuration for dynamically generating a test.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :count, :integer, default: 10
    field :time_limit, :integer

    field :mandatory_tags, {:array, :string}, default: []
    field :include_tags, {:array, :string}, default: []
    field :exclude_tags, {:array, :string}, default: []
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:count, :time_limit, :mandatory_tags, :include_tags, :exclude_tags])
    |> validate_required([:count])
    |> validate_number(:count, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_number(:time_limit, greater_than: 0)
  end
end
