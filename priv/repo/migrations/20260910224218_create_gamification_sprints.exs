defmodule Athena.Repo.Migrations.CreateGamificationSprints do
  use Ecto.Migration

  def change do
    create table(:gamification_sprints, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cohort_id, :binary_id, null: false
      add :title, :string, null: false
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime, null: false
      add :xp_multiplier, :decimal, null: false, default: 1.5
      add :created_by, :binary_id, null: false
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:gamification_sprints, [:cohort_id])
    create index(:gamification_sprints, [:starts_at, :ends_at])
  end
end
