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
    field :allowed_blur_attempts, :integer, default: 3

    embeds_many :slots, TicketSlot, on_replace: :delete
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:time_limit, :allowed_blur_attempts])
    |> cast_embed(:slots, with: &TicketSlot.changeset/2)
    |> validate_required([:allowed_blur_attempts])
    |> validate_number(:time_limit, greater_than: 0)
    |> validate_number(:allowed_blur_attempts, greater_than_or_equal_to: 0)
  end
end
