defmodule Athena.Repo.Migrations.AddDeepCopyFieldsToCourses do
  use Ecto.Migration

  def change do
    alter table(:courses) do
      add :source_course_id, references(:courses, type: :binary_id, on_delete: :nilify_all)
      add :copy_status, :string, null: false, default: "ready"
    end

    create index(:courses, [:source_course_id])
  end
end
