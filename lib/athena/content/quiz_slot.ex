defmodule Athena.Content.QuizSlot do
  @moduledoc """
  Embedded schema for a single slot in a Quiz Exam.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :id, :string
    field :count, :integer, default: 1
    field :tags, {:array, :string}, default: []
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :count, :tags])
    |> put_new_id()
    |> validate_required([:id])
    |> validate_number(:count, greater_than: 0)
  end

  defp put_new_id(changeset) do
    if get_field(changeset, :id) in [nil, ""] do
      put_change(changeset, :id, Ecto.UUID.generate())
    else
      changeset
    end
  end
end
