defmodule Athena.Repo.Migrations.CreateGamificationXpTables do
  use Ecto.Migration

  def change do
    create table(:gamification_xp_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :cohort_id, :binary_id
      add :source_type, :string, null: false
      add :source_id, :binary_id
      add :amount, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:gamification_xp_events, [:account_id])
    create index(:gamification_xp_events, [:cohort_id])

    create unique_index(:gamification_xp_events, [:account_id, :source_type, :source_id],
             where: "source_id IS NOT NULL",
             name: :gamification_xp_events_dedup_index
           )

    create table(:gamification_xp_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :block_type, :string, null: false
      add :base_amount, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gamification_xp_rules, [:block_type])

    create table(:gamification_account_stats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :total_xp, :integer, null: false, default: 0
      add :current_streak_weeks, :integer, null: false, default: 0
      add :longest_streak_weeks, :integer, null: false, default: 0
      add :current_combo, :integer, null: false, default: 0
      add :last_active_week, :date

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gamification_account_stats, [:account_id])

    execute(
      """
      INSERT INTO gamification_xp_rules (id, block_type, base_amount, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), 'text', 0, now(), now()),
        (gen_random_uuid(), 'video', 0, now(), now()),
        (gen_random_uuid(), 'image', 0, now(), now()),
        (gen_random_uuid(), 'attachment', 0, now(), now()),
        (gen_random_uuid(), 'file_assignment', 20, now(), now()),
        (gen_random_uuid(), 'quiz_question', 10, now(), now()),
        (gen_random_uuid(), 'code', 15, now(), now()),
        (gen_random_uuid(), 'quiz_exam', 40, now(), now()),
        (gen_random_uuid(), 'ticket_exam', 50, now(), now())
      """,
      "DELETE FROM gamification_xp_rules"
    )
  end
end
