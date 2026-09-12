defmodule Athena.Repo.Migrations.CreateGamificationLeagueResults do
  use Ecto.Migration

  def change do
    create table(:gamification_league_results, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cohort_id, :binary_id, null: false
      add :week_start, :date, null: false
      add :account_id, :binary_id, null: false
      add :weekly_xp, :integer, null: false, default: 0
      add :rank, :integer, null: false
      add :tier, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gamification_league_results, [:cohort_id, :week_start, :account_id],
             name: :gamification_league_results_unique_index
           )

    create index(:gamification_league_results, [:account_id])
  end
end
