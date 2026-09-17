defmodule Athena.Repo.Migrations.CreateTestRunSessions do
  use Ecto.Migration

  def change do
    create table(:test_run_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :course_id, :binary_id, null: false
      add :section_id, :binary_id, null: false
      add :instructor_account_id, :binary_id, null: false
      add :ephemeral_account_id, :binary_id, null: false
      add :status, :string, null: false, default: "active"
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:test_run_sessions, [:expires_at])
    create unique_index(:test_run_sessions, [:ephemeral_account_id])
  end
end
