defmodule Athena.Repo.Migrations.CreateCourseLibraryBlocks do
  use Ecto.Migration

  def change do
    create table(:course_library_blocks, primary_key: false) do
      add :course_id, references(:courses, on_delete: :delete_all, type: :binary_id),
        primary_key: true

      add :library_block_id, references(:library_blocks, on_delete: :restrict, type: :binary_id),
        primary_key: true

      timestamps(type: :utc_datetime)
    end

    create index(:course_library_blocks, [:course_id])
    create index(:course_library_blocks, [:library_block_id])
  end
end
