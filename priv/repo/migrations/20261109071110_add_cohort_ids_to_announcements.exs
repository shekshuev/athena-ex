defmodule Athena.Repo.Migrations.AddCohortIdsToAnnouncements do
  use Ecto.Migration

  def up do
    alter table(:announcements) do
      add :cohort_ids, {:array, :uuid}, null: false, default: []
    end

    create index(:announcements, [:cohort_ids], using: :gin)

    execute "UPDATE announcements SET cohort_ids = ARRAY[cohort_id] WHERE cohort_id IS NOT NULL"
  end

  def down do
    drop index(:announcements, [:cohort_ids])

    alter table(:announcements) do
      remove :cohort_ids
    end
  end
end
