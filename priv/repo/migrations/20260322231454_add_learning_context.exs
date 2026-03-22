defmodule Athena.Repo.Migrations.AddLearningContext do
  use Ecto.Migration

  def change do
    create table(:cohorts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create table(:instructors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, :binary_id, null: false
      add :title, :string, null: false
      add :bio, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:instructors, [:owner_id])

    create table(:cohort_instructors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cohort_id, references(:cohorts, on_delete: :delete_all, type: :binary_id), null: false

      add :instructor_id, references(:instructors, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cohort_instructors, [:cohort_id, :instructor_id])

    create table(:cohort_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :cohort_id, references(:cohorts, on_delete: :delete_all, type: :binary_id), null: false
      add :account_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cohort_memberships, [:cohort_id, :account_id])

    create table(:enrollments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :course_id, :binary_id, null: false
      add :account_id, :binary_id
      add :cohort_id, references(:cohorts, on_delete: :delete_all, type: :binary_id)

      add :status, :string, default: "active", null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:enrollments, :enrollment_target_check,
             check: "num_nonnulls(account_id, cohort_id) = 1"
           )

    create unique_index(:enrollments, [:course_id, :account_id], where: "account_id IS NOT NULL")
    create unique_index(:enrollments, [:course_id, :cohort_id], where: "cohort_id IS NOT NULL")

    create table(:block_progresses, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :block_id, :binary_id, null: false

      add :status, :string, null: false
      add :score, :integer
      add :payload, :map, default: %{}
      add :feedback, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:block_progresses, [:account_id, :block_id])
  end
end
