defmodule Athena.Gamification.XpRule do
  @moduledoc """
  Admin-configurable base XP award per `Athena.Content.Block` type.

  Seeded with defaults by migration; edited through the admin gamification
  settings page. Passive block types (`text`, `video`, `image`, `attachment`)
  default to zero so simply viewing content can't be farmed for XP or inflate
  a weekly streak.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @block_types ~w(text code quiz_question quiz_exam ticket_exam video image attachment file_assignment)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_xp_rules" do
    field :block_type, Ecto.Enum, values: @block_types
    field :base_amount, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for editing an XP rule's base amount.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:block_type, :base_amount])
    |> validate_required([:block_type, :base_amount])
    |> validate_number(:base_amount, greater_than_or_equal_to: 0)
    |> unique_constraint(:block_type)
  end
end
