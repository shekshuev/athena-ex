defmodule Athena.Repo.Migrations.AddVisibilityToCohortSchedules do
  use Ecto.Migration

  def change do
    alter table(:cohort_schedules) do
      add :visibility, :string
    end
  end
end
