defmodule Athena.Content.TicketExam do
  @moduledoc """
  Embedded schema for the `content` field of a `:ticket_exam` block.
  Stores the slots configuration for generating a deck-based assessment.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Athena.Content.TicketSlot

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :time_limit, :integer
    field :require_fullscreen, :boolean, default: false

    embeds_many :slots, TicketSlot, on_replace: :delete
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:time_limit, :require_fullscreen])
    |> cast_embed(:slots, with: &TicketSlot.changeset/2)
    |> validate_number(:time_limit, greater_than: 0)
  end
end
