defmodule Athena.Repo.Migrations.CreateGamificationBadges do
  use Ecto.Migration

  def change do
    create table(:gamification_badges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :title, :string, null: false
      add :description, :string
      add :icon, :string, null: false, default: "hero-star"
      add :rule, :map, null: false
      add :scope, :string, null: false, default: "global"
      add :scope_id, :binary_id
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gamification_badges, [:key])
    create index(:gamification_badges, [:is_active])

    create table(:gamification_badge_awards, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false

      add :badge_id, references(:gamification_badges, type: :binary_id, on_delete: :delete_all),
        null: false

      add :context, :map, default: %{}
      add :awarded_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gamification_badge_awards, [:account_id, :badge_id])
    create index(:gamification_badge_awards, [:badge_id])
  end
end
