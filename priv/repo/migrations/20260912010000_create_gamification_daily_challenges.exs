defmodule Athena.Repo.Migrations.CreateGamificationDailyChallenges do
  use Ecto.Migration

  def change do
    create table(:gamification_daily_challenges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :block_id, :binary_id, null: false
      add :assigned_date, :date, null: false
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gamification_daily_challenges, [:account_id, :assigned_date],
             name: :gamification_daily_challenges_unique_index
           )

    create index(:gamification_daily_challenges, [:block_id])
  end
end
