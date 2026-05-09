defmodule Athena.Repo.Migrations.DropCrossContextFkFromCohortSchedules do
  use Ecto.Migration

  def up do
    drop constraint(:cohort_schedules, "cohort_schedules_course_id_fkey")
  end

  def down do
    alter table(:cohort_schedules) do
      modify :course_id, references(:courses, type: :binary_id, on_delete: :cascade)
    end
  end
end
