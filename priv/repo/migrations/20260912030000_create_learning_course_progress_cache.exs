defmodule Athena.Repo.Migrations.CreateLearningCourseProgressCache do
  use Ecto.Migration

  def change do
    create table(:learning_course_progress_cache, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id
      add :cohort_id, :binary_id
      add :course_id, :binary_id, null: false
      add :completed_count, :integer, null: false, default: 0
      add :total_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    # Same duality as `block_progresses`: a `:team`-type cohort's progress
    # is one shared row per (cohort_id, course_id); an individually-tracked
    # enrollment (no team) is one row per (account_id, course_id).
    create unique_index(:learning_course_progress_cache, [:cohort_id, :course_id],
             where: "cohort_id IS NOT NULL",
             name: :course_progress_cache_team_index
           )

    create unique_index(:learning_course_progress_cache, [:account_id, :course_id],
             where: "cohort_id IS NULL",
             name: :course_progress_cache_account_index
           )
  end
end
