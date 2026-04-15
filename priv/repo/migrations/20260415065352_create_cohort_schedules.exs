defmodule Athena.Repo.Migrations.CreateCohortSchedules do
  use Ecto.Migration

  def change do
    create table(:cohort_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cohort_id, references(:cohorts, type: :binary_id, on_delete: :delete_all), null: false
      add :course_id, references(:courses, type: :binary_id, on_delete: :delete_all), null: false

      add :resource_type, :string, null: false
      add :resource_id, :binary_id, null: false

      add :unlock_at, :utc_datetime
      add :lock_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:cohort_schedules, [:cohort_id])
    create index(:cohort_schedules, [:course_id])
    create index(:cohort_schedules, [:resource_id, :resource_type])

    create unique_index(:cohort_schedules, [:cohort_id, :resource_id, :resource_type],
             name: :cohort_resource_unique_index
           )
  end
end
