defmodule Athena.Content.TicketSlot do
  @moduledoc """
  Embedded schema for a single slot in a Ticket Exam.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :id, :string
    field :tags, {:array, :string}, default: []
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :tags])
    |> put_new_id()
    |> validate_required([:id])
  end

  defp put_new_id(changeset) do
    if get_field(changeset, :id) in [nil, ""] do
      put_change(changeset, :id, Ecto.UUID.generate())
    else
      changeset
    end
  end
end
