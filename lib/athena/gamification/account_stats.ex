defmodule Athena.Gamification.AccountStats do
  @moduledoc """
  Cached per-account gamification counters (1-to-1 with `Athena.Identity.Account`).

  Kept as a denormalized cache — `total_xp` and `current_combo` are updated
  incrementally as XP is awarded; `current_streak_weeks` and
  `longest_streak_weeks` are updated by the weekly rollup job.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_account_stats" do
    field :account_id, :binary_id
    field :total_xp, :integer, default: 0
    field :current_streak_weeks, :integer, default: 0
    field :longest_streak_weeks, :integer, default: 0
    field :current_combo, :integer, default: 0
    field :last_active_week, :date

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or updating an account's cached stats.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(stats, attrs) do
    stats
    |> cast(attrs, [
      :account_id,
      :total_xp,
      :current_streak_weeks,
      :longest_streak_weeks,
      :current_combo,
      :last_active_week
    ])
    |> validate_required([:account_id])
    |> validate_number(:total_xp, greater_than_or_equal_to: 0)
    |> validate_number(:current_streak_weeks, greater_than_or_equal_to: 0)
    |> validate_number(:longest_streak_weeks, greater_than_or_equal_to: 0)
    |> validate_number(:current_combo, greater_than_or_equal_to: 0)
    |> unique_constraint(:account_id)
  end
end
