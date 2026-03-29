defmodule Athena.Content.QuizExam do
  @moduledoc """
  Embedded schema for the `content` field of a `:quiz_exam` block.
  Defines the rules for dynamic question generation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :limit, :integer, default: 10
    field :tags_any, {:array, :string}, default: []
    field :tags_required, {:array, :string}, default: []
    field :tags_exclude, {:array, :string}, default: []
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:limit, :tags_any, :tags_required, :tags_exclude])
    |> validate_required([:limit])
    |> validate_number(:limit, greater_than: 0, less_than_or_equal_to: 100)
  end
end
