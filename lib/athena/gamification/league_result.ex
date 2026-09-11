defmodule Athena.Gamification.LeagueResult do
  @moduledoc """
  A closed week's league standing snapshot for one cohort member. Only
  written by the weekly rollup job for weeks that have already ended — the
  current, still-open week is always computed live (see
  `Athena.Gamification.Leagues.current_week_standings/1`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @tiers ~w(top active quiet)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gamification_league_results" do
    field :cohort_id, :binary_id
    field :week_start, :date
    field :account_id, :binary_id
    field :weekly_xp, :integer, default: 0
    field :rank, :integer
    field :tier, Ecto.Enum, values: @tiers

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for one account's snapshotted league result.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(result, attrs) do
    result
    |> cast(attrs, [:cohort_id, :week_start, :account_id, :weekly_xp, :rank, :tier])
    |> validate_required([:cohort_id, :week_start, :account_id, :weekly_xp, :rank, :tier])
    |> unique_constraint([:cohort_id, :week_start, :account_id],
      name: :gamification_league_results_unique_index
    )
  end
end
