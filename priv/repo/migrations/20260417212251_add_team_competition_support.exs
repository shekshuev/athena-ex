defmodule Athena.Repo.Migrations.AddTeamCompetitionSupport do
  use Ecto.Migration

  def change do
    alter table(:courses) do
      add :type, :string, default: "standard", null: false
    end

    alter table(:cohorts) do
      add :type, :string, default: "academic", null: false
    end

    alter table(:submissions) do
      add :cohort_id, references(:cohorts, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:block_progresses) do
      add :cohort_id, references(:cohorts, type: :binary_id, on_delete: :delete_all)
    end

    drop unique_index(:block_progresses, [:account_id, :block_id])

    create unique_index(:block_progresses, [:cohort_id, :block_id],
             where: "cohort_id IS NOT NULL",
             name: :block_progresses_cohort_block_index
           )

    create unique_index(:block_progresses, [:account_id, :block_id],
             where: "cohort_id IS NULL",
             name: :block_progresses_account_block_index
           )
  end
end
