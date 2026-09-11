defmodule Athena.Gamification.XpEvent do
  @moduledoc """
  Append-only XP ledger entry.

  `source_id` is used for de-duplication: a `block_progress` source is only
  ever awarded once per `(account_id, source_type, source_id)` via a partial
  unique index, so re-completing (or re-processing) the same block does not
  inflate XP.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @source_types ~w(block_progress streak_bonus league_bonus sprint_bonus badge_bonus)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_xp_events" do
    field :account_id, :binary_id
    field :cohort_id, :binary_id
    field :source_type, Ecto.Enum, values: @source_types
    field :source_id, :binary_id
    field :amount, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for a new XP ledger entry.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:account_id, :cohort_id, :source_type, :source_id, :amount])
    |> validate_required([:account_id, :source_type, :amount])
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> unique_constraint([:account_id, :source_type, :source_id],
      name: :gamification_xp_events_dedup_index
    )
  end
end
