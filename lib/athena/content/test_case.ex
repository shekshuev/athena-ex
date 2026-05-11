defmodule Athena.Content.TestCase do
  @moduledoc """
  Represents a single input/output test case for a code challenge.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:input, :expected_output, :is_hidden, :weight]}

  @primary_key false
  embedded_schema do
    field :input, :string, default: ""
    field :expected_output, :string, default: ""
    field :is_hidden, :boolean, default: false
    field :weight, :integer, default: 10
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:input, :expected_output, :is_hidden, :weight])
    |> validate_required([:expected_output, :weight])
    |> validate_number(:weight, greater_than_or_equal_to: 0)
  end
end
